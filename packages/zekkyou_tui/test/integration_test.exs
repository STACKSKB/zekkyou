defmodule Zekkyou.TUI.IntegrationTest do
  use ExUnit.Case, async: false
  alias ExRatatui.Event.{Key, Paste}
  alias ExRatatui.Runtime
  alias Zekkyou.{Config, Service}
  alias Zekkyou.TUI.App

  defmodule Provider do
    @behaviour Alto.Provider
    def describe(_), do: %{}

    def stream(_request, _sink, opts) do
      send(Keyword.fetch!(opts, :owner), {:working, self()})

      receive do
        :finish -> {:ok, %{message: "Finished while detached", tool_calls: []}}
      end
    end
  end

  test "native headless terminal submits, detaches, and reconnects to the same resident task" do
    dir = Path.join(System.tmp_dir!(), "zek-tui-#{Base.encode16(:crypto.strong_rand_bytes(6))}")
    File.mkdir_p!(dir)

    config =
      Config.new(
        workspace: dir,
        state_dir: Path.join(dir, "state"),
        profiles: %{
          "chat" =>
            Alto.Config.new(
              provider: {Provider, owner: self()},
              loop: Alto.chat_loop(),
              tools: [],
              run_timeout: 10_000
            )
        }
      )

    start_supervised!({Service, config: config, name: make_ref()})
    on_exit(fn -> File.rm_rf!(dir) end)
    opts = [test_mode: {120, 36}, name: nil, socket: Config.socket_path(config), profile: "chat"]
    {:ok, first} = App.start_link(opts)
    ready(first)
    assert Runtime.snapshot(first).render_count > 0
    assert Runtime.snapshot(first).dimensions == {120, 36}
    refute Runtime.snapshot(first).polling_enabled?
    assert :ok = Runtime.inject_event(first, %Paste{content: "Inspect my repository"})
    assert :ok = Runtime.inject_event(first, %Key{code: "enter", kind: "press"})
    assert_receive {:working, provider}, 2_000
    ready(first)
    session = state(first).model.selected_id
    client = state(first).model.client.pid
    quit(first)
    eventually(fn -> not Process.alive?(client) end)
    assert Process.alive?(provider)
    send(provider, :finish)

    {:ok, second} = App.start_link(opts)
    ready(second)
    assert :ok = Runtime.inject_event(second, %Key{code: "tab", kind: "press"})
    assert :ok = Runtime.inject_event(second, %Key{code: "down", kind: "press"})
    ready(second)
    assert state(second).model.selected_id == session

    eventually(fn ->
      Enum.any?(state(second).model.entries, &(&1.text == "Finished while detached"))
    end)

    assert ExRatatui.get_buffer_content(:sys.get_state(second).terminal_ref) =~
             "Finished while detached"

    assert Runtime.snapshot(second).render_count > 2
    quit(second)
  end

  defp state(pid), do: :sys.get_state(pid).user_state

  defp ready(pid),
    do:
      eventually(fn ->
        s = state(pid)
        s.pending == nil and s.model.connection == "connected"
      end)

  defp quit(pid) do
    monitor = Process.monitor(pid)
    Runtime.inject_event(pid, %Key{code: "q", modifiers: ["ctrl"], kind: "press"})
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 2_000
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: flunk("terminal did not reach expected state")

  defp eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(20)
          eventually(fun, attempts - 1)
        )
  end
end
