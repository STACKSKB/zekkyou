defmodule Zekkyou.ParentRecoveryTest do
  use ExUnit.Case, async: false

  alias Alto.{Effect, Event, OperationLog, Queue, Transition}
  alias Alto.Runner.Budget.Account
  alias Alto.Subagents.{Continuation, Journal}
  alias Zekkyou.{CLI, ChildRuns, Config, ParentRuns, Service, Tasks}

  defmodule ParentLoop do
    @behaviour Alto.Loop

    def init(task, _spec) do
      send(:persistent_term.get({__MODULE__, :observer}), {:parent_planned, task})

      Transition.continue(%{task: task}, [
        Effect.spawn_agents(%{agents: [%{id: "worker", task: "work"}]})
      ])
    end

    def handle_event(%Event{type: :subagents_completed, data: %{results: results}}, state, _spec) do
      call = %{id: "integrate-once", name: "integrate", arguments: %{"value" => "joined"}}
      Transition.continue(Map.put(state, :results, results), [Effect.invoke_tool(call)])
    end

    def handle_event(%Event{type: :tool_completed}, state, _spec),
      do: Transition.stop(state, state.results)

    def handle_event(_event, state, _spec), do: Transition.continue(state)
    def dump_checkpoint(state, _spec), do: {:ok, state}
    def load_checkpoint(state, _spec), do: {:ok, state}
  end

  defmodule IntegrateTool do
    @behaviour Alto.Tool
    def name, do: :integrate

    def schema,
      do: %{
        description: "Record one integration.",
        parameters: %{
          type: "object",
          properties: %{value: %{type: "string"}},
          required: ["value"]
        }
      }

    def execution_mode, do: :exclusive
    def approval, do: :never

    def run(%{"value" => value}, _context) do
      send(:persistent_term.get({__MODULE__, :observer}), {:integrated, value})
      {:ok, %{integrated: value}}
    end
  end

  defmodule BlockingProvider do
    @behaviour Alto.Provider
    def describe(_), do: %{}

    def stream(_request, _sink, opts) do
      [worker | _] = Process.get(:"$callers")
      send(Keyword.fetch!(opts, :observer), {:child_entered, self(), worker})

      receive do
        :release -> {:ok, %{message: "retained output", tool_calls: []}}
      end
    end
  end

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "zekkyou-parent-recovery-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    name = make_ref()

    profile =
      Alto.Config.new(
        provider: {BlockingProvider, observer: self()},
        loop:
          Alto.loop(ParentLoop,
            subagents:
              Alto.Subagents.bounded(
                max_depth: 1,
                max_children: 1,
                max_concurrency: 1,
                journal: ChildRuns.ledger(name)
              )
          ),
        tools: [IntegrateTool],
        continuation_store: ParentRuns.ledger(name),
        checkpoint_version: "parent-recovery-v1",
        max_effects: 50,
        max_model_requests: 20
      )

    config =
      Config.new(
        workspace: dir,
        state_dir: Path.join(dir, "state"),
        scheduling: [workers: 1, poll_ms: 10, run_timeout: 15_000],
        profiles: %{"parent" => profile}
      )

    :persistent_term.put({ParentLoop, :observer}, self())
    :persistent_term.put({IntegrateTool, :observer}, self())

    on_exit(fn ->
      :persistent_term.erase({ParentLoop, :observer})
      :persistent_term.erase({IntegrateTool, :observer})
      File.rm_rf!(dir)
    end)

    start_supervised!({Service, config: config, name: name})
    %{dir: dir, name: name, config: config}
  end

  defp parked_task!(name, id) do
    assert {:ok, _} =
             Tasks.command(name, "submit", %{
               "id" => id,
               "profile" => "parent",
               "task" => "original task",
               "delay_ms" => 60_000
             })

    ledger = Service.component(name, :ledger)
    queue = Service.component(name, :queue)
    {:ok, record} = Queue.lookup(queue, id)

    assert :ok =
             OperationLog.record_intent(ledger, id, "zekkyou_task", id, %{
               key: id,
               generation_id: record.generation_id,
               payload: record.payload
             })

    assert :ok = OperationLog.record_attempt(ledger, id, "interrupted-attempt")

    assert :ok =
             OperationLog.record_outcome(ledger, id, "interrupted-attempt", :unknown, %{
               reason: "process lost"
             })

    assert :ok = Queue.cancel_pending(queue, id)
    task = task!(name, id)
    assert task["status"] == "requires_operator"
    task
  end

  defp start_parent!(config, name, id, dir) do
    {:ok, profile} = Config.resolve(config, "parent")

    {:ok, account} =
      Account.open(ParentRuns.budgets(name), "task:" <> id,
        max_effects: 50,
        max_model_requests: 20
      )

    opts =
      profile ++
        [
          continuation_key: id,
          budget_account: account,
          cwd: dir,
          session: :new,
          session_dir: Path.join([dir, "state", "sessions"]),
          run_timeout: 15_000
        ]

    assert {:ok, handle} = Alto.start("original task", opts)
    assert_receive {:parent_planned, "original task"}, 2_000
    assert_receive {:child_entered, provider, worker}, 2_000
    {handle, provider, worker, account}
  end

  defp parent_worker(%Alto.Runner.Handle{state: %Alto.Runner.TaskHost.Handle{pid: host}}),
    do: :sys.get_state(host).task.pid

  defp only_cell!(name) do
    [key] = OperationLog.keys(ParentRuns.ledger(name))
    {:ok, entry} = OperationLog.recovery(ParentRuns.ledger(name), key)
    identity = %{"key" => key, "generation" => entry.recovery["generation"]}
    {:ok, cell} = Continuation.restore(ParentRuns.ledger(name), identity)
    {cell, identity}
  end

  defp task!(name, id) do
    {:ok, %{"task" => task}} = Tasks.command(name, "get", %{"id" => id})
    task
  end

  defp eventually(name, id, status, tries \\ 150)
  defp eventually(_name, id, status, 0), do: flunk("#{id} did not become #{status}")

  defp eventually(name, id, status, tries) do
    case task!(name, id) do
      %{"status" => ^status} = task ->
        task

      _ ->
        Process.sleep(20)
        eventually(name, id, status, tries - 1)
    end
  end

  test "parked task resumes retained children once with revision and generation fences", %{
    dir: dir,
    name: name,
    config: config
  } do
    parked_task!(name, "recoverable")
    {handle, provider, worker, account} = start_parent!(config, name, "recoverable", dir)
    parent = parent_worker(handle)
    assert :erlang.suspend_process(parent)
    child_monitor = Process.monitor(worker)
    send(provider, :release)
    assert_receive {:DOWN, ^child_monitor, :process, ^worker, :normal}, 2_000

    {cell, identity} = only_cell!(name)
    assert {:ok, %{phase: :pending, metadata: metadata}} = Continuation.read(cell)
    {:ok, journal} = Journal.restore(ChildRuns.ledger(name), metadata["journal"])
    assert {:ok, %{results: [{"worker", result}]}} = Journal.join(journal)
    assert result.output == "retained output"

    monitor = Process.monitor(parent)
    Process.exit(parent, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^parent, :killed}, 2_000
    stop_supervised!(Service)
    start_supervised!({Service, config: config, name: name})

    task = eventually(name, "recoverable", "requires_operator")
    candidate = task["parent_continuation"]
    assert candidate.identity == identity
    assert candidate.phase == :pending
    assert is_binary(candidate.session_id)

    payload = %{
      "id" => "recoverable",
      "key" => identity["key"],
      "generation" => identity["generation"],
      "revision" => task["revision"],
      "continuation_revision" => candidate.revision
    }

    assert {:error, :use_parent_recovery} =
             Tasks.command(name, "reconcile", %{
               "id" => "recoverable",
               "revision" => task["revision"],
               "resolution" => "retry",
               "note" => "unsafe generic retry"
             })

    assert {:error, :stale_revision} =
             Tasks.command(name, "recover", %{payload | "revision" => task["revision"] - 1})

    assert {:error, :stale_or_claimed_parent_continuation} =
             Tasks.command(name, "recover", %{payload | "generation" => String.duplicate("f", 32)})

    assert {:error, :stale_or_claimed_parent_continuation} =
             Tasks.command(name, "recover", %{
               payload
               | "continuation_revision" => candidate.revision - 1
             })

    assert {:ok, _} = Tasks.command(name, "recover", payload)
    assert_receive {:integrated, "joined"}, 3_000
    eventually(name, "recoverable", "completed")
    refute_receive {:parent_planned, _}, 50
    refute_receive {:child_entered, _, _}, 50
    refute_receive {:integrated, _}, 50

    {:ok, restored} = Continuation.restore(ParentRuns.ledger(name), identity)
    assert {:ok, %{phase: :claimed}} = Continuation.read(restored)
    {:ok, restored_journal} = Journal.restore(ChildRuns.ledger(name), metadata["journal"])
    assert {:ok, %{packet: %{"join" => receipt}}} = Journal.read(restored_journal)

    assert receipt["continuation"] == identity
    assert {:ok, counts} = Account.read(%{account | ledger: ParentRuns.budgets(name)})
    assert counts.packet["model_requests_used"] == 1
    assert {:error, :task_not_parked} = Tasks.command(name, "recover", payload)
  end

  test "an incomplete dispatched child cannot be recovered or generically retried", %{
    dir: dir,
    name: name,
    config: config
  } do
    parked_task!(name, "incomplete")
    {handle, provider, worker, _account} = start_parent!(config, name, "incomplete", dir)
    {cell, identity} = only_cell!(name)
    {:ok, pending} = Continuation.read(cell)
    parent = parent_worker(handle)
    monitor = Process.monitor(parent)
    Process.exit(parent, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^parent, :killed}, 2_000
    for pid <- [provider, worker], Process.alive?(pid), do: Process.exit(pid, :kill)

    task = task!(name, "incomplete")

    payload = %{
      "id" => "incomplete",
      "key" => identity["key"],
      "generation" => identity["generation"],
      "revision" => task["revision"],
      "continuation_revision" => pending.revision
    }

    assert {:error, {:child_pending, "worker", "dispatched"}} =
             Tasks.command(name, "recover", payload)

    assert {:error, :use_parent_recovery} =
             Tasks.command(name, "reconcile", %{
               "id" => "incomplete",
               "revision" => task["revision"],
               "resolution" => "retry",
               "note" => "child still dispatched"
             })

    assert Continuation.read(cell) == {:ok, pending}
    refute_receive {:child_entered, _, _}, 50
    refute_receive {:integrated, _}, 50
  end

  test "removing the trusted continuation store cannot turn a parked parent into a fresh run", %{
    dir: dir,
    name: name,
    config: config
  } do
    parked_task!(name, "profile-changed")
    {handle, provider, worker, _account} = start_parent!(config, name, "profile-changed", dir)
    {cell, identity} = only_cell!(name)
    {:ok, snapshot} = Continuation.read(cell)
    parent = parent_worker(handle)
    monitor = Process.monitor(parent)
    Process.exit(parent, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^parent, :killed}, 2_000
    for pid <- [provider, worker], Process.alive?(pid), do: Process.exit(pid, :kill)

    original = config.profiles["parent"].run_options
    changed_profile = Alto.Config.new(Keyword.delete(original, :continuation_store))
    changed_config = %{config | profiles: %{"parent" => changed_profile}}
    stop_supervised!(Service)
    start_supervised!({Service, config: changed_config, name: name})
    task = eventually(name, "profile-changed", "requires_operator")

    assert {:error, :use_parent_recovery} =
             Tasks.command(name, "reconcile", %{
               "id" => "profile-changed",
               "revision" => task["revision"],
               "resolution" => "retry",
               "note" => "profile changed"
             })

    assert {:error, _} =
             Tasks.command(name, "recover", %{
               "id" => "profile-changed",
               "revision" => task["revision"],
               "key" => identity["key"],
               "generation" => identity["generation"],
               "continuation_revision" => snapshot.revision
             })

    assert task!(name, "profile-changed")["status"] == "requires_operator"
    refute_receive {:parent_planned, _}, 50
    refute_receive {:child_entered, _, _}, 50
  end

  test "a claimed parent frame cannot be granted to a parked task", %{
    dir: dir,
    name: name,
    config: config
  } do
    parked_task!(name, "already-claimed")
    {handle, provider, _worker, _account} = start_parent!(config, name, "already-claimed", dir)
    send(provider, :release)
    assert {:ok, _result} = Alto.await(handle, 5_000)
    assert_receive {:integrated, "joined"}, 2_000

    {cell, identity} = only_cell!(name)
    assert {:ok, %{phase: :claimed, revision: revision}} = Continuation.read(cell)
    task = task!(name, "already-claimed")

    assert {:error, :stale_or_claimed_parent_continuation} =
             Tasks.command(name, "recover", %{
               "id" => "already-claimed",
               "revision" => task["revision"],
               "key" => identity["key"],
               "generation" => identity["generation"],
               "continuation_revision" => revision
             })

    assert task!(name, "already-claimed")["status"] == "requires_operator"
    refute_receive {:integrated, _}, 50
  end

  test "task-recover CLI rejects absent and nonpositive fences" do
    base = ["task-recover", "task-1", "parent:key"]
    assert {:error, :invalid_parent_recovery_request} = CLI.run(base)

    for bad <- [
          base ++ ["--revision", "0", "--generation", "abc", "--continuation-revision", "1"],
          base ++ ["--revision", "1", "--generation", "", "--continuation-revision", "1"],
          base ++ ["--revision", "1", "--generation", "abc", "--continuation-revision", "0"]
        ] do
      assert {:error, :invalid_parent_recovery_request} = CLI.run(bad)
    end
  end
end
