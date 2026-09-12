defmodule Zekkyou.LifecycleTest do
  use ExUnit.Case, async: false

  alias Alto.{Effect, Event, OperationLog, Transition}
  alias Alto.Runner.Budget.Account
  alias Alto.Subagents.{Continuation, Journal}
  alias Zekkyou.{ChildRuns, Config, Lifecycle, ParentRuns, Service, Tasks}

  defmodule Provider do
    @behaviour Alto.Provider
    def describe(_), do: %{}

    def stream(request, _sink, _opts) do
      if Enum.any?(request.messages, &(&1["role"] == "tool")),
        do: {:ok, %{message: "done", tool_calls: []}},
        else: {:ok, %{message: "child", tool_calls: []}}
    end
  end

  defmodule ParentLoop do
    @behaviour Alto.Loop

    def init(_task, _spec),
      do:
        Transition.continue(%{}, [Effect.spawn_agents(%{agents: [%{id: "child", task: "work"}]})])

    def handle_event(%Event{type: :subagents_completed, data: %{results: results}}, state, _spec),
      do:
        Transition.continue(Map.put(state, :results, results), [
          Effect.invoke_tool(%{id: "integrate", name: "integrate", arguments: %{}})
        ])

    def handle_event(%Event{type: :tool_completed}, state, _spec),
      do: Transition.stop(state, :done)

    def handle_event(_event, state, _spec), do: Transition.continue(state)
    def dump_checkpoint(state, _spec), do: {:ok, state}
    def load_checkpoint(state, _spec), do: {:ok, state}
  end

  defmodule Integrate do
    @behaviour Alto.Tool
    def name, do: :integrate
    def schema, do: %{description: "integrate", parameters: %{type: "object", properties: %{}}}
    def execution_mode, do: :exclusive
    def approval, do: :never
    def run(_, _), do: {:ok, "integrated"}
  end

  defmodule Echo do
    @behaviour Alto.Loop
    def init(task, _spec), do: Transition.stop(task, task)
    def handle_event(_, state, _spec), do: Transition.continue(state)
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "zek-lifecycle-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    name = make_ref()

    profile =
      Alto.Config.new(
        provider: {Provider, []},
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
        tools: [Integrate],
        continuation_store: ParentRuns.ledger(name),
        checkpoint_version: "lifecycle-v1",
        max_effects: 20,
        max_model_requests: 20
      )

    config =
      Config.new(
        workspace: dir,
        state_dir: Path.join(dir, "state"),
        scheduling: [workers: 1, poll_ms: 10, run_timeout: 10_000],
        profiles: %{
          "parent" => profile,
          "echo" => Alto.Config.new(provider: nil, loop: Alto.loop(Echo))
        }
      )

    start_supervised!({Service, config: config, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, name: name, config: config}
  end

  test "terminal cleanup is idempotent", %{name: name} do
    assert {:ok, _} =
             Tasks.command(name, "submit", %{
               "id" => "done",
               "profile" => "parent",
               "task" => "work"
             })

    task = eventually(name, "done", "completed")

    assert {:ok, %{status: "cleaned"}} =
             Tasks.command(name, "cleanup", %{"id" => "done", "revision" => task["revision"]})

    assert {:ok, %{status: "cleaned"}} =
             Tasks.command(name, "cleanup", %{"id" => "done", "revision" => task["revision"]})
  end

  test "ordinary terminal cleanup is idempotent", %{name: name} do
    assert {:ok, _} =
             Tasks.command(name, "submit", %{
               "id" => "ordinary-done",
               "profile" => "echo",
               "task" => "work"
             })

    task = eventually(name, "ordinary-done", "completed")

    assert {:ok, %{status: "cleaned", resources: 0}} =
             Tasks.command(name, "cleanup", %{
               "id" => "ordinary-done",
               "revision" => task["revision"]
             })

    assert {:ok, %{status: "cleaned", resources: 0}} =
             Tasks.command(name, "cleanup", %{
               "id" => "ordinary-done",
               "revision" => task["revision"]
             })

    assert {:error, :stale_revision} =
             Tasks.command(name, "cleanup", %{
               "id" => "ordinary-done",
               "revision" => task["revision"] + 1
             })
  end

  test "explicit nil budget account is treated as task-owned", %{name: name, config: config} do
    profile = config.profiles["parent"]
    nil_budget = Alto.Config.new(Keyword.put(profile.run_options, :budget_account, nil))
    config = %{config | profiles: Map.put(config.profiles, "nil-budget", nil_budget)}
    stop_supervised!(Service)
    start_supervised!({Service, config: config, name: name})

    assert {:ok, _} =
             Tasks.command(name, "submit", %{
               "id" => "nil-budget",
               "profile" => "nil-budget",
               "task" => "work"
             })

    task = eventually(name, "nil-budget", "completed")

    {:ok, entry} = OperationLog.recovery(ParentRuns.budgets(name), "task:nil-budget")

    account = %Account{
      ledger: ParentRuns.budgets(name),
      key: "task:nil-budget",
      generation: entry.recovery["generation"]
    }

    assert {:ok, %{state: :active}} = Account.read(account)

    assert {:ok, %{status: "cleaned", resources: 3}} =
             Tasks.command(name, "cleanup", %{
               "id" => "nil-budget",
               "revision" => task["revision"]
             })

    assert {:ok, %{state: :closed}} = Account.read(account)
  end

  test "cleanup refuses running, pending, and stale tasks", %{name: name} do
    assert {:ok, _} =
             Tasks.command(name, "submit", %{
               "id" => "pending",
               "profile" => "parent",
               "task" => "work",
               "delay_ms" => 60_000
             })

    assert {:error, :task_not_terminal} =
             Tasks.command(name, "cleanup", %{"id" => "pending", "revision" => 1})

    assert {:ok, _} =
             Tasks.command(name, "submit", %{
               "id" => "running",
               "profile" => "parent",
               "task" => "work"
             })

    assert {:error, :task_not_terminal} =
             Tasks.command(name, "cleanup", %{"id" => "running", "revision" => 1})

    task = eventually(name, "running", "completed")

    assert {:error, :stale_revision} =
             Tasks.command(name, "cleanup", %{
               "id" => "running",
               "revision" => task["revision"] + 1
             })
  end

  test "interrupted cleanup resumes after task record eviction", %{name: name, config: config} do
    config = restart_with_one_task!(name, config)
    resources = parent_resources!(name, "interrupted", :claimed, true)
    terminal = terminal_task!(name, "interrupted", "generation-one")
    {key, _plan} = manifest!(name, terminal, resources)
    assert :ok = OperationLog.record_attempt(Lifecycle.ledger(name), key, "retire-resources")
    {:ok, journal} = Journal.read(resources.batch)
    assert :ok = Journal.retire(resources.batch, journal.revision)

    _ = terminal_task!(name, "evict-task", "generation-two")

    assert {:error, :not_found} =
             OperationLog.recovery(Service.component(name, :ledger), "interrupted")

    assert {:error, :cleanup_plan_not_found} =
             Lifecycle.resume(config, name, "interrupted", terminal.revision + 1)

    assert {:ok, %{task_id: "interrupted", status: "cleaned", resources: 3}} =
             Tasks.command(name, "cleanup", %{
               "id" => "interrupted",
               "revision" => terminal.revision
             })

    assert {:ok, %{state: :retired}} = Journal.read(resources.batch)
    assert {:ok, %{state: :retired}} = Continuation.read(resources.cell)
    assert {:ok, %{state: :closed}} = Account.read(resources.account)

    assert {:ok, %{status: {:decided, :completed, _}}} =
             OperationLog.recovery(Lifecycle.ledger(name), key)

    assert {:ok, %{status: "cleaned"}} =
             Tasks.command(name, "cleanup", %{
               "id" => "interrupted",
               "revision" => terminal.revision
             })
  end

  test "resume fences changed store identity", %{name: name, config: config} do
    resources = parent_resources!(name, "fenced", :claimed, true)
    terminal = terminal_task!(name, "fenced", "generation-fenced")
    _ = manifest!(name, terminal, resources)
    profile = config.profiles["parent"]

    changed =
      Alto.Config.new(
        Keyword.put(profile.run_options, :continuation_store, ChildRuns.ledger(name))
      )

    changed_config = %{config | profiles: Map.put(config.profiles, "parent", changed)}

    assert {:error, :cleanup_plan_mismatch} =
             Lifecycle.resume(changed_config, name, "fenced", terminal.revision)

    assert {:ok, %{state: :active}} = Continuation.read(resources.cell)
    assert {:ok, %{state: :active}} = Journal.read(resources.batch)
    assert {:ok, %{state: :active}} = Account.read(resources.account)
  end

  test "resume skips an evicted generation and preserves its replacement", %{
    name: name,
    config: config
  } do
    config = restart_with_one_task!(name, config)
    resources = parent_resources!(name, "replace", :claimed, true)
    terminal = terminal_task!(name, "replace", "generation-old")
    _ = manifest!(name, terminal, resources)
    {:ok, old} = Continuation.read(resources.cell)
    assert :ok = Continuation.retire(resources.cell, old.revision)

    {:ok, filler} =
      Continuation.open(ParentRuns.ledger(name), "filler", %{}, %{
        "journal" => Journal.identity(resources.batch),
        "host_key" => "other"
      })

    {:ok, pending} = Continuation.read(filler)
    {:ok, ready} = Continuation.ready(filler, pending.revision, %{})
    {:ok, claimed} = Continuation.claim(filler, ready.revision)
    assert :ok = Continuation.retire(filler, claimed.revision)

    {:ok, replacement} =
      Continuation.open(ParentRuns.ledger(name), resources.cell.key, %{}, %{
        "journal" => Journal.identity(resources.batch),
        "host_key" => "new-task"
      })

    assert replacement.generation != resources.cell.generation
    assert {:ok, %{state: :active, phase: :pending}} = Continuation.read(replacement)

    assert {:ok, %{status: "cleaned"}} =
             Lifecycle.resume(config, name, "replace", terminal.revision)

    assert {:ok, %{state: :active, phase: :pending}} = Continuation.read(replacement)
    assert {:ok, %{state: :closed}} = Account.read(resources.account)
  end

  test "retained parent resources block task id reuse after task and queue eviction", %{
    name: name,
    config: config
  } do
    restart_with_one_task!(name, config)

    assert {:ok, _} =
             Tasks.command(name, "submit", %{
               "id" => "reuse",
               "profile" => "parent",
               "task" => "work"
             })

    _ = eventually(name, "reuse", "completed")

    assert {:ok, _} =
             Tasks.command(name, "submit", %{
               "id" => "evict",
               "profile" => "echo",
               "task" => "work"
             })

    _ = eventually(name, "evict", "completed")
    assert {:error, :not_found} = OperationLog.recovery(Service.component(name, :ledger), "reuse")
    assert {:error, :unknown_task} = Tasks.command(name, "get", %{"id" => "reuse"})

    assert {:error, :task_id_retained} =
             Tasks.command(name, "submit", %{
               "id" => "reuse",
               "profile" => "parent",
               "task" => "new work"
             })
  end

  test "account-only cleanup closes the host-owned budget", %{name: name, config: config} do
    {:ok, account} =
      Account.open(ParentRuns.budgets(name), "task:account-only",
        max_effects: 20,
        max_model_requests: 20
      )

    terminal = synthetic_terminal(name, "account-only", "generation-account")
    assert {:ok, %{resources: 1}} = Lifecycle.cleanup(config, name, terminal)
    assert {:ok, %{state: :closed}} = Account.read(account)
  end

  test "a root rule loop without a child journal closes its account", %{
    name: name,
    config: config
  } do
    rule =
      Alto.Config.new(
        provider: nil,
        loop: Alto.rule_loop(steps: ["integrate"]),
        tools: [Integrate],
        continuation_store: ParentRuns.ledger(name),
        checkpoint_version: "lifecycle-v1",
        max_effects: 20,
        max_model_requests: 20
      )

    config = %{config | profiles: Map.put(config.profiles, "rule", rule)}
    stop_supervised!(Service)
    start_supervised!({Service, config: config, name: name})

    assert {:ok, _} =
             Tasks.command(name, "submit", %{
               "id" => "rule-no-journal",
               "profile" => "rule",
               "task" => "{}"
             })

    task = eventually(name, "rule-no-journal", "completed")
    {:ok, entry} = OperationLog.recovery(ParentRuns.budgets(name), "task:rule-no-journal")

    account = %Account{
      ledger: ParentRuns.budgets(name),
      key: "task:rule-no-journal",
      generation: entry.recovery["generation"]
    }

    assert {:ok, %{state: :active}} = Account.read(account)

    assert {:ok, %{resources: 1}} =
             Tasks.command(name, "cleanup", %{
               "id" => "rule-no-journal",
               "revision" => task["revision"]
             })

    assert {:ok, %{state: :closed}} = Account.read(account)
    [key] = OperationLog.keys(Lifecycle.ledger(name))
    {:ok, cleanup} = OperationLog.recovery(Lifecycle.ledger(name), key)
    assert Map.keys(cleanup.recovery["stores"]) |> Enum.sort() == ["budget", "parent"]

    resources = parent_resources!(name, "missing-journal", :claimed, true)
    terminal = synthetic_terminal(name, "missing-journal", "generation-missing")

    terminal =
      put_in(terminal, [:recovery, :payload, "profile"], "rule")

    assert {:error, :child_journal_required} = Lifecycle.cleanup(config, name, terminal)
    assert {:ok, %{state: :active}} = Continuation.read(resources.cell)
    assert {:ok, %{state: :active}} = Account.read(resources.account)
  end

  test "cleanup leaves an externally shared account active", %{name: name, config: config} do
    {:ok, external} =
      Account.open(ParentRuns.budgets(name), "shared-external",
        max_effects: 20,
        max_model_requests: 20
      )

    resources = parent_resources!(name, "external", :claimed, true, external)
    profile = config.profiles["parent"]
    shared = Alto.Config.new(Keyword.put(profile.run_options, :budget_account, external))
    config = %{config | profiles: Map.put(config.profiles, "parent", shared)}
    terminal = synthetic_terminal(name, "external", "generation-external")

    assert {:ok, %{resources: 2}} = Lifecycle.cleanup(config, name, terminal)
    assert {:ok, %{state: :retired}} = Continuation.read(resources.cell)
    assert {:ok, %{state: :retired}} = Journal.read(resources.batch)
    assert {:ok, %{state: :active}} = Account.read(external)
  end

  test "pending, ready, and unacknowledged parent frames cannot be cleaned", %{
    name: name,
    config: config
  } do
    for {phase, acknowledged?} <- [{:pending, false}, {:ready, false}, {:claimed, false}] do
      id = "incomplete-#{phase}"
      resources = parent_resources!(name, id, phase, acknowledged?)
      terminal = synthetic_terminal(name, id, "generation-#{phase}")

      assert {:error, :unconsumed_parent_resources} = Lifecycle.cleanup(config, name, terminal)
      key = id <> ":" <> terminal.recovery[:generation_id]
      assert {:error, :not_found} = OperationLog.recovery(Lifecycle.ledger(name), key)
      assert {:ok, %{state: :active}} = Continuation.read(resources.cell)
      assert {:ok, %{state: :active}} = Journal.read(resources.batch)
      assert {:ok, %{state: :active}} = Account.read(resources.account)
    end
  end

  defp restart_with_one_task!(name, config) do
    config = %{config | scheduling: Keyword.put(config.scheduling, :max_tasks, 1)}
    stop_supervised!(Service)
    start_supervised!({Service, config: config, name: name})
    config
  end

  defp parent_resources!(name, id, phase, acknowledge?, existing_account \\ nil) do
    account =
      if existing_account do
        existing_account
      else
        {:ok, account} =
          Account.open(ParentRuns.budgets(name), "task:" <> id,
            max_effects: 20,
            max_model_requests: 20
          )

        account
      end

    {:ok, batch} = Journal.open(ChildRuns.ledger(name), "children:" <> id, ["child"])
    {:ok, _} = Journal.skip(batch, "child", :done)
    packet = %{"budget" => %{"account" => Account.identity(account)}}

    {:ok, cell} =
      Continuation.open(ParentRuns.ledger(name), "parent:" <> id, packet, %{
        "journal" => Journal.identity(batch),
        "host_key" => id,
        "operation_seq" => 1
      })

    if phase in [:ready, :claimed] do
      {:ok, pending} = Continuation.read(cell)
      {:ok, ready} = Continuation.ready(cell, pending.revision, packet)
      if phase == :claimed, do: {:ok, _} = Continuation.claim(cell, ready.revision)
    end

    if acknowledge? do
      {:ok, joined} = Journal.join(batch)

      {:ok, _} =
        Journal.acknowledge(batch, joined.revision, %{
          "continuation" => Continuation.identity(cell)
        })
    end

    %{account: account, batch: batch, cell: cell}
  end

  defp synthetic_terminal(name, id, generation, revision \\ 7) do
    {:ok, binding} = OperationLog.identity(ParentRuns.ledger(name))

    %{
      revision: revision,
      recovery: %{
        generation_id: generation,
        payload: %{"id" => id, "profile" => "parent", "parent_store" => binding}
      }
    }
  end

  defp terminal_task!(name, id, generation) do
    ledger = Service.component(name, :ledger)
    terminal = synthetic_terminal(name, id, generation)
    :ok = OperationLog.record_intent(ledger, id, "zekkyou_task", nil, terminal.recovery)
    :ok = OperationLog.record_attempt(ledger, id, "fake-attempt")
    :ok = OperationLog.record_outcome(ledger, id, "fake-attempt", :completed, %{})
    {:ok, recovered} = OperationLog.recovery(ledger, id)
    recovered
  end

  defp manifest!(name, terminal, resources) do
    id = terminal.recovery[:payload]["id"]
    generation = terminal.recovery[:generation_id]
    {:ok, journal} = Journal.read(resources.batch)
    {:ok, cell} = Continuation.read(resources.cell)
    {:ok, account} = Account.read(resources.account)

    resource = fn role, identity, snapshot ->
      %{"role" => role, "identity" => identity, "revision" => snapshot.revision}
    end

    stores = %{
      "parent" => ParentRuns.ledger(name),
      "journal" => ChildRuns.ledger(name),
      "budget" => ParentRuns.budgets(name)
    }

    bindings =
      Map.new(stores, fn {role, server} ->
        {:ok, identity} = OperationLog.identity(server)
        {role, identity}
      end)

    plan = %{
      "task" => id,
      "generation" => generation,
      "task_revision" => terminal.revision,
      "profile" => terminal.recovery[:payload]["profile"],
      "parent_store" => terminal.recovery[:payload]["parent_store"],
      "stores" => bindings,
      "resources" => [
        resource.("journal", Journal.identity(resources.batch), journal),
        resource.("parent", Continuation.identity(resources.cell), cell),
        resource.("budget", Account.identity(resources.account), account)
      ]
    }

    key = id <> ":" <> generation

    :ok =
      OperationLog.record_intent(Lifecycle.ledger(name), key, "zekkyou_task_cleanup", nil, plan)

    {key, plan}
  end

  defp eventually(name, id, status, tries \\ 300)
  defp eventually(_name, _id, _status, 0), do: flunk("task did not finish")

  defp eventually(name, id, status, tries) do
    case Tasks.command(name, "get", %{"id" => id}) do
      {:ok, %{"task" => %{"status" => ^status} = task}} ->
        task

      _ ->
        Process.sleep(20)
        eventually(name, id, status, tries - 1)
    end
  end
end
