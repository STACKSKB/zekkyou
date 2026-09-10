defmodule Zekkyou.ServiceTest do
  use ExUnit.Case, async: false

  defmodule Loop do
    @behaviour Alto.Loop
    def init(task, _spec), do: Alto.Transition.stop(task, task)
    def handle_event(_event, state, _spec), do: Alto.Transition.continue(state)
  end

  test "resident executes a providerless task and persists its session independently of clients" do
    dir = Path.join(System.tmp_dir!(), "zekkyou-service-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    config =
      Zekkyou.Config.new(
        workspace: dir,
        state_dir: Path.join(dir, "state"),
        profiles: %{
          "local" => Alto.Config.new(provider: nil, loop: Alto.loop(Loop))
        }
      )

    name = make_ref()
    pid = start_supervised!({Zekkyou.Service, config: config, name: name})
    assert Process.alive?(pid)
    registry = Zekkyou.Service.registry(name)
    :ok = Alto.FrontEnd.Registry.attach(registry, self(), nil, 1, [:durable])
    assert {:ok, run} = Alto.FrontEnd.Registry.start_run(registry, "local", "hello")
    assert is_binary(run)
    assert {:error, _} = Alto.FrontEnd.Registry.start_run(registry, "missing", "hello")
    session = Alto.FrontEnd.Registry.run_session(registry, run)
    assert is_binary(session)
    assert {:ok, %{mode: mode}} = File.stat(config.state_dir)
    assert Bitwise.band(mode, 0o777) == 0o700
    assert File.exists?(Zekkyou.Config.socket_path(config))
    await_result(registry, run)

    assert {:ok, records} =
             Alto.Session.read(session, session_dir: Path.join(config.state_dir, "sessions"))

    assert Enum.any?(records, &(&1["type"] == "completed"))
  end

  defp await_result(registry, run, attempts \\ 100)
  defp await_result(_registry, _run, 0), do: flunk("resident run did not finish")

  defp await_result(registry, run, attempts) do
    Alto.FrontEnd.Registry.pull(registry, self(), 100)

    receive do
      {:alto_notification, {:result, ^run, :ok, "hello", _}} -> :ok
    after
      20 -> await_result(registry, run, attempts - 1)
    end
  end
end
