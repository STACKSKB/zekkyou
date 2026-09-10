defmodule Zekkyou.RunnerProfilesTest do
  use ExUnit.Case, async: false

  alias Alto.FrontEnd.Registry, as: Runs
  alias Zekkyou.{Config, Service, Tasks}

  defmodule Echo do
    @behaviour Alto.Loop
    def init(task, _), do: Alto.Transition.stop(task, task)
    def handle_event(_, state, _), do: Alto.Transition.continue(state)
  end

  defmodule BlockingProvider do
    @behaviour Alto.Provider
    def describe(_), do: %{}

    def stream(_request, _sink, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:provider_started, self()})

      receive do
        :finish -> {:ok, %{message: "finished", tool_calls: []}}
      end
    end
  end

  defmodule ProbeRunner do
    @behaviour Alto.Runner
    defmodule Handle do
      @enforce_keys [:host]
      defstruct [:host]
    end

    def run(task, opts) do
      send(
        Process.whereis(:zekkyou_runner_probe),
        {:runner_seen, self(), Keyword.fetch!(opts, :runner_options)}
      )

      Alto.Runner.Stepped.run(task, opts)
    end

    def start(task, opts) do
      {:ok, host} =
        Alto.Runner.TaskHost.start(
          fn ref -> run(task, Keyword.put(opts, :cancel_ref, ref)) end,
          opts
        )

      {:ok, %Handle{host: host}}
    end

    def await(%Handle{host: host}, timeout), do: Alto.Runner.TaskHost.await(host, timeout)
    def cancel(%Handle{host: host}, reason), do: Alto.Runner.TaskHost.cancel(host, reason)
    def terminate(%Handle{host: host}, reason), do: Alto.Runner.TaskHost.terminate(host, reason)
    def subscribe(%Handle{host: host}, pid), do: Alto.Runner.TaskHost.subscribe(host, pid)
  end

  test "trusted runner and runner_options survive both config resolvers" do
    options = [
      runner: Alto.Runner.Stepped,
      runner_options: [mode: :automatic],
      run_timeout: 2_000,
      max_model_requests: 99,
      max_effects: 99
    ]

    config = Config.new(workspace: File.cwd!(), profiles: %{"p" => Alto.Config.new(options)})
    assert {:ok, ^options} = Config.resolve(config, "p")
    assert {:ok, ^options} = Tasks.resolve(config, "p")

    capped =
      Config.new(
        workspace: File.cwd!(),
        scheduling: [run_timeout: 1_000, max_model_requests: 7, max_effects: 8],
        profiles: %{"p" => Alto.Config.new(options)}
      )

    assert {:ok, scheduled} = Tasks.resolve(capped, "scheduled/p")
    assert scheduled[:runner] == Alto.Runner.Stepped
    assert scheduled[:runner_options] == [mode: :automatic]
    assert scheduled[:run_timeout] == 1_000
    assert scheduled[:max_model_requests] == 7
    assert scheduled[:max_effects] == 8
  end

  test "scheduled service executes and cancels through the configured Stepped runner" do
    dir = temp_dir("service")

    config =
      Config.new(
        workspace: dir,
        state_dir: Path.join(dir, "state"),
        scheduling: [workers: 1, poll_ms: 10, run_timeout: 2_000],
        profiles: %{
          "echo" =>
            Alto.Config.new(
              provider: nil,
              loop: Alto.loop(Echo),
              runner: Alto.Runner.Stepped,
              runner_options: [mode: :automatic]
            ),
          "blocked" =>
            Alto.Config.new(
              provider: {BlockingProvider, test_pid: self()},
              loop: Alto.chat_loop(),
              runner: Alto.Runner.Stepped,
              runner_options: [mode: :automatic]
            )
        }
      )

    name = make_ref()
    start_supervised!({Service, config: config, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)

    assert {:ok, _} =
             Tasks.command(name, "submit", %{"id" => "done", "profile" => "echo", "task" => "ok"})

    assert eventually(name, "done", "completed")

    assert {:ok, _} =
             Tasks.command(name, "submit", %{
               "id" => "stop",
               "profile" => "blocked",
               "task" => "wait"
             })

    assert_receive {:provider_started, _provider}, 2_000
    running = eventually(name, "stop", "running")
    assert is_binary(running["run_id"])
    assert :ok = Runs.cancel(Service.registry(name), running["run_id"], :test_stop)
    assert eventually(name, "stop", "cancelled")
  end

  test "custom non-Task handle observes exactly inherited runner options on parent and child" do
    dir = temp_dir("custom")
    Process.register(self(), :zekkyou_runner_probe)
    on_exit(fn -> File.rm_rf!(dir) end)
    opts = [mode: :automatic]

    config =
      Config.new(
        workspace: dir,
        state_dir: Path.join(dir, "state"),
        profiles: %{
          "custom" =>
            Alto.Config.new(
              runner: ProbeRunner,
              runner_options: opts,
              loop:
                Alto.loop(Zekkyou.RunnerProfilesTest.SpawnOnceLoop,
                  subagents: Alto.Subagents.bounded(max_depth: 1)
                ),
              provider: {Zekkyou.RunnerProfilesTest.AnswerProvider, answer: "parent"}
            )
        }
      )

    name = make_ref()
    start_supervised!({Service, config: config, name: name})
    registry = Service.registry(name)
    assert {:ok, run} = Runs.start_run(registry, "custom", "parent task")
    assert :ok = Runs.attach(registry, self(), run, 1, [])
    assert eventually_run(registry, run)

    assert {:ok,
            {:ok,
             %Alto.Runner.Result{
               output: {:completed, %{id: "child", status: :ok, output: "parent"}}
             }}} = Runs.run_result(registry, run)

    assert_receive {:runner_seen, _parent, ^opts}, 1_000
    assert_receive {:runner_seen, _child, ^opts}, 1_000
    refute_receive {:runner_seen, _, _}, 100
  end

  defmodule SpawnOnceLoop do
    @behaviour Alto.Loop
    def init(_task, _),
      do:
        Alto.Transition.continue(%{}, [
          Alto.Effect.spawn_agent(%{id: "child", task: "child task"})
        ])

    def handle_event(%Alto.Event{type: :subagent_completed, data: data}, _, _),
      do: Alto.Transition.stop(:done, {:completed, data})

    def handle_event(%Alto.Event{type: :subagent_failed, data: data}, _, _),
      do: Alto.Transition.stop(:done, {:failed, data})

    def handle_event(_, state, _), do: Alto.Transition.continue(state)
  end

  defmodule AnswerProvider do
    @behaviour Alto.Provider
    def describe(_), do: %{}
    def stream(_request, _sink, opts), do: {:ok, %{message: opts[:answer], tool_calls: []}}
  end

  defp eventually_run(registry, run, tries \\ 200)
  defp eventually_run(_registry, _run, 0), do: flunk("run did not finish")

  defp eventually_run(registry, run, tries) do
    case Runs.run_result(registry, run) do
      {:ok, _} ->
        :ok

      :running ->
        Process.sleep(10)
        eventually_run(registry, run, tries - 1)
    end
  end

  defp eventually(name, id, status, tries \\ 200)
  defp eventually(_name, _id, _status, 0), do: flunk("task did not reach expected status")

  defp eventually(name, id, status, tries) do
    case Tasks.command(name, "get", %{"id" => id}) do
      {:ok, %{"task" => %{"status" => ^status} = task}} ->
        task

      _ ->
        Process.sleep(10)
        eventually(name, id, status, tries - 1)
    end
  end

  defp temp_dir(label) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "zekkyou-runner-#{label}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    dir
  end
end
