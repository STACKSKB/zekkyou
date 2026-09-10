defmodule Zekkyou.TUI.AppTest do
  use ExUnit.Case, async: true
  alias ExRatatui.Event.{Key, Paste}
  alias Zekkyou.TUI.App

  defmodule Console do
    def new(_),
      do: %{
        tasks: [%{id: "run", title: "Running", status: "running"}],
        selected_id: "run",
        entries: [],
        notice: "",
        client: nil,
        connection: "connected"
      }

    def perform(model, {:submit, _}, _), do: Map.put(model, :notice, "Sent")
    def perform(model, _, _), do: model
    def close(_), do: :ok
  end

  test "quit only acts on press; control keys and named keys never become text" do
    {:ok, state} = App.mount(console_module: Console)

    assert {:noreply, ^state} =
             App.handle_event(%Key{code: "q", kind: "release", modifiers: ["ctrl"]}, state)

    assert {:noreply, ^state} = App.handle_event(%Key{code: "z", modifiers: ["ctrl"]}, state)
    assert {:noreply, ^state} = App.handle_event(%Key{code: "delete"}, state)

    assert {:stop, ^state} =
             App.handle_event(%Key{code: "q", kind: "press", modifiers: ["ctrl"]}, state)
  end

  test "paste is bounded in bytes with valid Unicode and strips terminal controls" do
    {:ok, state} = App.mount(console_module: Console)

    {:noreply, state} =
      App.handle_event(%Paste{content: "\e" <> String.duplicate("猫", 30_000)}, state)

    assert byte_size(state.draft) <= 65_536
    assert String.valid?(state.draft)
    refute state.draft =~ "\e"
  end

  test "running tasks remain selectable" do
    {:ok, state} = App.mount(console_module: Console)
    {:noreply, state} = App.handle_event(%Key{code: "tab"}, state)
    {:noreply, state} = App.handle_event(%Key{code: "down"}, state)
    assert %Task{} = state.pending
    App.terminate(:normal, state)
  end

  test "a completed send preserves edits typed while the request was pending" do
    {:ok, state} = App.mount(console_module: Console)
    {:noreply, state} = App.handle_event(%Paste{content: "original"}, state)
    {:noreply, state} = App.handle_event(%Key{code: "enter"}, state)
    {:noreply, state} = App.handle_event(%Paste{content: " plus edits"}, state)
    ref = state.pending.ref
    assert_receive {^ref, result}
    {:noreply, state} = App.handle_info({ref, result}, state)
    assert state.draft == "original plus edits"
    assert state.pending == nil
  end
end
