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

  defmodule ParkedConsole do
    def new(_),
      do: %{
        tasks: [%{id: "parked", title: "Parked", status: "requires_operator"}],
        selected_id: "parked",
        entries: [],
        notice: "",
        client: nil,
        connection: "connected"
      }

    def perform(model, {:reconcile, _resolution, _note}, _owner),
      do: Map.put(model, :notice, "Decision recorded")

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

    assert byte_size(state.draft) <= 32_000
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

  test "parked tasks turn exact slash commands into reconciliation actions" do
    {:ok, state} = App.mount(console_module: ParkedConsole)
    {:noreply, state} = App.handle_event(%Paste{content: "/retry safe to retry"}, state)
    {:noreply, state} = App.handle_event(%Key{code: "enter"}, state)
    ref = state.pending.ref
    assert_receive {^ref, {model, {:reconcile, "retry", "safe to retry"}}}
    assert model.notice == "Decision recorded"

    {:noreply, state} =
      App.handle_info({ref, {model, {:reconcile, "retry", "safe to retry"}}}, state)

    assert state.draft == ""
  end

  test "slash text on a normal task remains a submission" do
    {:ok, state} = App.mount(console_module: Console)
    {:noreply, state} = App.handle_event(%Paste{content: "/retry ordinary text"}, state)
    {:noreply, state} = App.handle_event(%Key{code: "enter"}, state)
    ref = state.pending.ref
    assert_receive {^ref, {_model, {:submit, "/retry ordinary text"}}}
  end

  test "a reconcile response preserves edits made while it was pending" do
    {:ok, state} = App.mount(console_module: ParkedConsole)
    {:noreply, state} = App.handle_event(%Paste{content: "/failed reviewed"}, state)
    {:noreply, state} = App.handle_event(%Key{code: "enter"}, state)
    ref = state.pending.ref
    {:noreply, state} = App.handle_event(%Paste{content: " newer"}, state)
    assert_receive {^ref, {model, {:reconcile, "failed", "reviewed"}}}

    {:noreply, state} =
      App.handle_info({ref, {model, {:reconcile, "failed", "reviewed"}}}, state)

    assert state.draft == "/failed reviewed newer"
  end
end
