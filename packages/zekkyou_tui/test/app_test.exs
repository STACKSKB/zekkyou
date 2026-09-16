defmodule Zekkyou.TUI.AppTest do
  use ExUnit.Case, async: true
  alias ExRatatui.Event.{Key, Mouse, Paste, Resize}
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

    def perform(model, {:workspace, "/bad"}, _),
      do: Map.put(model, :notice, "Request rejected: missing folder")

    def perform(model, {:workspace, path}, _),
      do:
        Map.merge(model, %{
          selected_id: nil,
          workspace_root: path,
          notice: "Workspace opened: " <> path
        })

    def perform(model, {:select_workspace, id}, _) do
      project = Enum.find(model.projects, &(&1["id"] == id))
      Map.merge(model, %{workspace_id: id, workspace_root: project["root"], selected_id: nil})
    end

    def perform(model, {:select, id}, _), do: Map.put(model, :selected_id, id)

    def perform(model, :new, _), do: Map.put(model, :selected_id, nil)

    def perform(model, {:submit, _}, _), do: Map.put(model, :notice, "Sent")
    def perform(model, _, _), do: model
    def close(_), do: :ok
    def complete_folders(_, _), do: {:ok, []}
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

  defmodule PollingConsole do
    def new(opts),
      do: Console.new(opts) |> Map.put(:client, self()) |> Map.put(:test_owner, opts[:test_owner])

    def perform(model, :poll, _owner) do
      send(model.test_owner, :service_polled)
      model
    end

    def perform(model, _, _owner), do: model
    def close(_), do: :ok
  end

  test "service refresh ticks reach the app through the real terminal runtime" do
    start_supervised!(
      {App, console_module: PollingConsole, test_owner: self(), test_mode: {140, 40}, name: nil}
    )

    assert_receive :service_polled, 3_000
  end

  test "new approval clears stale scroll and selection and is readable in wide and narrow views" do
    request = %{
      "id" => "approval-ls",
      "tool" => "run_command",
      "arguments" => %{"program" => "ls"},
      "details" => %{
        "command" => %{
          "requested_program" => "ls",
          "executable" => "/usr/bin/ls",
          "args" => ["-la"],
          "cwd" => "/workspace"
        }
      }
    }

    for {width, height} <- [{140, 40}, {70, 24}] do
      {:ok, state} = App.mount(console_module: Console, test_mode: {width, height})

      task =
        state.model.tasks |> hd() |> Map.merge(%{status: "waiting_approval", approval: request})

      model =
        Map.merge(state.model, %{
          tasks: [task],
          detail: "%{raw: args}",
          entries: [%{kind: :assistant, text: String.duplicate("old history\n", 100)}]
        })

      worker = Task.async(fn -> {model, :poll} end)
      assert_receive {ref, {^model, :poll}}

      state = %{
        state
        | pending: worker,
          scroll: 500,
          focus: :tasks,
          selection: %{Alto.TUI.Selection.new() | active?: true}
      }

      {:noreply, shown} = App.handle_info({ref, {model, :poll}}, state)
      assert shown.scroll == 0
      refute shown.selection.active?
      terminal = ExRatatui.init_test_terminal(width, height)
      :ok = ExRatatui.draw(terminal, App.render(shown, %{width: width, height: height}))
      buffer = ExRatatui.get_buffer_content(terminal)
      assert buffer =~ "Approval required"
      assert buffer =~ "ls -la"
      assert buffer =~ "/workspace"
      refute buffer =~ "%{raw: args}"
      worker = Task.async(fn -> {model, :poll} end)
      assert_receive {ref, {^model, :poll}}

      {:noreply, same} =
        App.handle_info({ref, {model, :poll}}, %{shown | pending: worker, scroll: 2})

      assert same.scroll == 2
    end
  end

  test "selection autoscrolls context and transcript and keeps the copied scroll position" do
    for pane <- [:details, :transcript] do
      {:ok, state} = App.mount(console_module: Console, test_mode: {140, 40})
      text = Enum.map_join(0..99, "\n", &"line #{&1}")

      model =
        if pane == :details,
          do: Map.put(state.model, :detail, text),
          else: Map.put(state.model, :entries, [%{kind: :assistant, text: text}])

      state = %{state | model: model}
      rect = Map.fetch!(Alto.TUI.Layout.calculate(140, 40), pane)
      down = %Mouse{kind: "down", button: "left", x: rect.x + 1, y: rect.y + 1}
      {:noreply, state} = App.handle_event(down, state)
      assert state.selection.scroll != nil

      {:noreply, state} =
        App.handle_event(
          %{down | kind: "drag", x: rect.x + rect.width - 2, y: rect.y + rect.height - 1},
          state
        )

      before = Alto.TUI.Selection.text(state.selection)

      {:noreply, state} =
        App.handle_info({:tui_selection_scroll, state.selection.scroll.token}, state)

      key = if pane == :details, do: :details_scroll, else: :scroll
      assert Map.fetch!(state, key) > 0
      assert String.starts_with?(Alto.TUI.Selection.text(state.selection), before)
      token = state.selection.scroll.token
      {:noreply, copied} = App.handle_event(%Key{code: "c", modifiers: ["ctrl"]}, state)
      assert copied.clipboard_text =~ "line 0"
      refute copied.clipboard_text =~ "Ctrl"
      assert Map.fetch!(copied, key) == Map.fetch!(state, key)

      assert {:noreply, ^copied, render?: false} =
               App.handle_info({:tui_selection_scroll, token}, copied)
    end
  end

  test "connection wait is visible before any service response and animates" do
    {:ok, state} = App.mount(console_module: Console, test_mode: {140, 40})
    {first, rect} = List.last(App.render(state, %{width: 140, height: 40}))
    assert first.text =~ "waiting for connection"
    assert {:noreply, state, render?: true} = App.handle_info(:tui_activity_tick, state)
    {second, ^rect} = List.last(App.render(state, %{width: 140, height: 40}))
    refute first.text == second.text
    idle = %{state | pending_action: nil, model: Map.put(state.model, :tasks, [])}
    assert {:noreply, _, render?: false} = App.handle_info(:tui_activity_tick, idle)
  end

  test "effort command opens a capability picker and selection dispatches the chosen value" do
    {:ok, state} = App.mount(console_module: Console, test_mode: {140, 40})
    {:noreply, state} = App.handle_event(%Key{code: "g", modifiers: ["ctrl"]}, state)
    {:noreply, state} = App.handle_event(%Key{code: "e"}, state)
    assert state.pending_action == :efforts
    ref = state.pending.ref
    assert_receive {^ref, {model, :efforts}}, 1000
    model = Map.put(model, :effort_catalog, %{"efforts" => ["low", "high"]})
    {:noreply, state} = App.handle_info({ref, {model, :efforts}}, state)
    assert state.effort_picker.choices == [nil, "low", "high"]
    {:noreply, state} = App.handle_event(%Key{code: "down"}, state)
    {:noreply, state} = App.handle_event(%Key{code: "enter"}, state)
    assert state.pending_action == {:effort, "low"}
    ref = state.pending.ref
    assert_receive {^ref, {model, action}}, 1000
    App.handle_info({ref, {model, action}}, state)
  end

  test "context scrolling clamps at the last wrapped text row" do
    {:ok, state} = App.mount(console_module: Console, test_mode: {140, 40})

    state = %{
      state
      | model: Map.put(state.model, :detail, String.duplicate("details\n", 100) <> "END"),
        focus: :details,
        details_scroll: 50_000
    }

    cap = Zekkyou.TUI.View.details_bottom(state.model, 140, 40)
    {:noreply, state} = App.handle_event(%Key{code: "page_down"}, state)
    assert state.details_scroll == cap
    rect = Alto.TUI.Layout.calculate(140, 40).details

    {:noreply, state} =
      App.handle_event(%Mouse{kind: "scroll_down", x: rect.x + 2, y: rect.y + 2}, state)

    assert state.details_scroll == cap
    terminal = ExRatatui.init_test_terminal(140, 40)
    ExRatatui.draw(terminal, App.render(state, %{width: 140, height: 40}))
    assert ExRatatui.get_buffer_content(terminal) =~ "END"
  end

  test "folder completion ignores stale responses and Tab accepts a current service suggestion" do
    {:ok, state} = App.mount(console_module: Console, test_mode: {140, 40})
    {:noreply, state} = App.handle_event(%Key{code: "g", modifiers: ["ctrl"]}, state)
    {:noreply, state} = App.handle_event(%Key{code: "w"}, state)
    old = state.workspace_form.revision
    {:noreply, state} = App.handle_event(%Paste{content: "/remote/p"}, state)
    {:noreply, state} = App.handle_info({:workspace_suggestions, old, {:ok, ["/wrong/"]}}, state)
    refute "/wrong/" in state.workspace_form.suggestions
    revision = state.workspace_form.revision

    {:noreply, state} =
      App.handle_info({:workspace_suggestions, revision, {:ok, ["/remote/project/"]}}, state)

    {:noreply, state} = App.handle_event(%Key{code: "tab"}, state)
    assert Alto.TUI.WorkspaceForm.path(state.workspace_form) == "/remote/project/"
    {:noreply, state} = App.handle_event(%Key{code: "esc"}, state)

    assert {:noreply, ^state} =
             App.handle_info({:workspace_suggestions, revision, {:ok, ["/old/"]}}, state)
  end

  test "Tab waits for service suggestions and requests children after completing a prefix" do
    {:ok, state} = App.mount(console_module: Console, test_mode: {140, 40})
    {:noreply, state} = App.handle_event(%Key{code: "g", modifiers: ["ctrl"]}, state)
    {:noreply, state} = App.handle_event(%Key{code: "w"}, state)
    {:noreply, state} = App.handle_event(%Paste{content: "/hom"}, state)
    revision = state.workspace_form.revision
    {:noreply, state} = App.handle_event(%Key{code: "tab"}, state)
    assert state.workspace_form.revision == revision
    assert Alto.TUI.WorkspaceForm.path(state.workspace_form) == "/hom"

    {:noreply, state} =
      App.handle_info(
        {:workspace_suggestions, revision, {:ok, %{folders: ["/home/"], completion: "/home/"}}},
        state
      )

    assert Alto.TUI.WorkspaceForm.path(state.workspace_form) == "/home/"
    next = state.workspace_form.revision
    assert next != revision
    assert_receive {:complete_workspace, ^next}, 500

    {:noreply, state} =
      App.handle_info(
        {:workspace_suggestions, next,
         {:ok, %{folders: ["/home/alice/", "/home/bob/"], completion: "/home/"}}},
        state
      )

    assert state.workspace_form.suggestions == ["/home/alice/", "/home/bob/"]
    {:noreply, state} = App.handle_event(%Key{code: "tab"}, state)
    assert Alto.TUI.WorkspaceForm.path(state.workspace_form) == "/home/"
  end

  test "Ctrl+G N creates a task in the existing folder without a workspace form" do
    {:ok, state} = App.mount(console_module: Console, test_mode: {140, 40})
    state = %{state | draft: "draft", model: Map.put(state.model, :workspace_root, "/current")}
    {:noreply, state} = App.handle_event(%Key{code: "g", modifiers: ["ctrl"]}, state)
    {:noreply, state} = App.handle_event(%Key{code: "n"}, state)
    ref = state.pending.ref
    assert_receive {^ref, {model, :new}}
    {:noreply, state} = App.handle_info({ref, {model, :new}}, state)
    assert state.model.selected_id == nil
    assert state.model.workspace_root == "/current"
    assert state.workspace_form == nil
    assert state.draft == "draft"
  end

  test "workspace sidebar navigates both ways and mouse actions open folders or compose" do
    {:ok, state} = App.mount(console_module: Console, test_mode: {140, 40})

    projects =
      Enum.map(1..3, fn n ->
        %{"id" => "p#{n}", "name" => "Project #{n}", "root" => "/p#{n}"}
      end)

    tasks =
      Enum.map(1..3, fn n ->
        %{
          id: "t#{n}",
          title: "Task #{n}",
          status: "completed",
          workspace_id: "p#{n}",
          cwd: "/p#{n}"
        }
      end)

    state = %{
      state
      | draft: "keep draft",
        focus: :tasks,
        model:
          Map.merge(state.model, %{
            projects: projects,
            tasks: tasks,
            selected_id: "t2",
            workspace_id: "p2"
          })
    }

    header = sidebar_key(state, "up")
    assert header.model.workspace_id == "p2"
    assert header.model.selected_id == nil
    assert header.focus == :tasks
    previous = sidebar_key(header, "up")
    assert previous.model.workspace_id == "p1"
    assert previous.model.selected_id == nil
    task = sidebar_key(previous, "down")
    assert task.model.selected_id == "t1"
    next = sidebar_key(task, "down")
    assert next.model.workspace_id == "p2"
    assert next.model.selected_id == nil

    rail = Alto.TUI.Layout.calculate(140, 40).rail

    for {row, id} <- [{1, "p2"}, {3, "p3"}] do
      clicked = sidebar_click(state, rail.x + 3, rail.y + 2 + row) |> finish_sidebar_action()
      assert clicked.model.workspace_id == id
      assert clicked.model.selected_id == nil
      assert clicked.focus == :composer
      assert clicked.workspace_form == nil
      assert clicked.draft == "keep draft"
    end

    clicked = sidebar_click(state, rail.x + 3, rail.y + 4) |> finish_sidebar_action()
    assert clicked.model.selected_id == "t2"
    assert clicked.focus == :tasks

    form = sidebar_click(state, rail.x + 3, rail.y + 1)
    assert form.workspace_form.kind == :workspace_form
    assert form.model.selected_id == "t2"
    {:noreply, form} = App.handle_event(%Paste{content: "/new/workspace"}, form)
    {:noreply, opening} = App.handle_event(%Key{code: "enter"}, form)
    opened = finish_sidebar_action(opening)
    assert opened.model.workspace_root == "/new/workspace"
    assert opened.model.selected_id == nil
    assert opened.workspace_form == nil
    assert opened.draft == "keep draft"
  end

  defp sidebar_key(state, code) do
    {:noreply, next} = App.handle_event(%Key{code: code}, state)
    finish_sidebar_action(next)
  end

  defp sidebar_click(state, x, y) do
    mouse = %Mouse{kind: "down", button: "left", x: x, y: y}
    {:noreply, pressed} = App.handle_event(mouse, state)
    {:noreply, clicked} = App.handle_event(%{mouse | kind: "up"}, pressed)
    clicked
  end

  defp finish_sidebar_action(state) do
    ref = state.pending.ref
    assert_receive {^ref, result}, 1000
    {:noreply, next} = App.handle_info({ref, result}, state)
    next
  end

  test "Ctrl+G W edits a folder separately from the draft and opens a new workspace" do
    {:ok, state} = App.mount(console_module: Console, test_mode: {140, 40})
    state = %{state | draft: "keep my draft"}
    {:noreply, state} = App.handle_event(%Key{code: "g", modifiers: ["ctrl"]}, state)
    {:noreply, state} = App.handle_event(%Key{code: "w"}, state)
    assert state.workspace_form.host == "the service host"

    state =
      Enum.reduce(String.graphemes("/Another/Project!"), state, fn code, state ->
        modifiers = if code in ["A", "P", "!"], do: ["shift"], else: []

        {:noreply, next} =
          App.handle_event(%Key{code: code, kind: "press", modifiers: modifiers}, state)

        next
      end)

    assert Alto.TUI.WorkspaceForm.path(state.workspace_form) == "/Another/Project!"
    assert state.draft == "keep my draft"
    {:noreply, state} = App.handle_event(%Key{code: "enter"}, state)
    ref = state.pending.ref
    assert_receive {^ref, {model, {:workspace, "/Another/Project!"}}}
    {:noreply, state} = App.handle_info({ref, {model, {:workspace, "/Another/Project!"}}}, state)
    assert state.workspace_form == nil
    assert state.model.workspace_root == "/Another/Project!"
    assert state.model.selected_id == nil
    assert state.draft == "keep my draft"
    assert state.focus == :composer
  end

  test "workspace validation keeps the dialog open and Escape preserves the selected task" do
    {:ok, state} = App.mount(console_module: Console, test_mode: {140, 40})
    {:noreply, state} = App.handle_event(%Key{code: "g", modifiers: ["ctrl"]}, state)
    {:noreply, state} = App.handle_event(%Key{code: "w"}, state)
    {:noreply, state} = App.handle_event(%Paste{content: "/bad"}, state)
    {:noreply, state} = App.handle_event(%Key{code: "enter"}, state)
    ref = state.pending.ref
    assert_receive {^ref, result}
    {:noreply, state} = App.handle_info({ref, result}, state)
    assert state.workspace_form.error =~ "missing folder"
    assert state.model.selected_id == "run"
    {:noreply, state} = App.handle_event(%Key{code: "esc"}, state)
    assert state.workspace_form == nil
    assert state.model.selected_id == "run"
  end

  test "Alt opts into copying UI text using the shared Alto selection layer" do
    owner = self()

    {:ok, state} =
      App.mount(
        console_module: Console,
        test_mode: {140, 40},
        clipboard_write: fn text ->
          send(owner, {:clipboard, text})
          :ok
        end,
        clipboard_read: fn -> {:error, :unavailable} end
      )

    state = %{
      state
      | model: Map.merge(state.model, %{detail: "task detail", notice: "ready"}),
        draft: "draft text"
    }

    geometry = Alto.TUI.Layout.calculate(140, 40)

    for rect <- [
          geometry.rail,
          geometry.transcript,
          geometry.details,
          geometry.composer,
          geometry.settings,
          geometry.status
        ] do
      {:noreply, pressed} =
        App.handle_event(
          %Mouse{kind: "down", button: "left", modifiers: ["alt"], x: rect.x, y: rect.y},
          state
        )

      {:noreply, selected} =
        App.handle_event(
          %Mouse{kind: "up", button: "left", x: rect.x + rect.width - 1, y: rect.y},
          pressed
        )

      assert selected.selection.active?
      text = Alto.TUI.Selection.text(selected.selection)
      assert text != ""
      {:noreply, copied} = App.handle_event(%Key{code: "c", modifiers: ["ctrl"]}, selected)
      assert_receive {:clipboard, ^text}
      assert copied.pending == nil
      assert copied.clipboard_text == text
      refute copied.selection.active?
    end

    {:noreply, pasted} =
      App.handle_event(%Key{code: "v", modifiers: ["ctrl"]}, %{
        state
        | focus: :tasks,
          clipboard_text: "\n猫"
      })

    assert pasted.focus == :composer
    assert pasted.draft == "draft text\n猫"
    assert pasted.pending == nil
    assert {:stop, _} = App.handle_event(%Key{code: "c", modifiers: ["ctrl"]}, pasted)
  end

  test "box selection excludes neighbors and the Copy menu works without keyboard shortcuts" do
    owner = self()

    {:ok, state} =
      App.mount(
        console_module: Console,
        test_mode: {140, 40},
        clipboard_write: fn text ->
          send(owner, {:clipboard, text})
          :ok
        end
      )

    state = %{state | model: Map.put(state.model, :detail, "first\nsecond")}
    layout = Alto.TUI.Layout.calculate(140, 40)
    down = %Mouse{kind: "down", button: "left", x: layout.details.x + 1, y: 1}
    {:noreply, state} = App.handle_event(down, state)
    {:noreply, state} = App.handle_event(%{down | kind: "up", x: 0, y: 3}, state)
    assert Alto.TUI.Selection.text(state.selection) == "first\nsecond\n"

    {:noreply, state} =
      App.handle_event(%Mouse{kind: "down", button: "right", x: 139, y: 39}, state)

    menu = state.selection.menu
    down = %{down | x: menu.x + 2, y: menu.y}
    {:noreply, state} = App.handle_event(down, state)
    {:noreply, copied} = App.handle_event(%{down | kind: "up"}, state)
    assert_receive {:clipboard, "first\nsecond\n"}
    assert copied.model.notice == "Copied selection"
    refute copied.selection.active?
    assert copied.pending == nil
  end

  test "default selection excludes UI labels and shows nothing until right-click" do
    {:ok, state} = App.mount(console_module: Console, test_mode: {140, 40})
    layout = Alto.TUI.Layout.calculate(140, 40)

    for {x, y} <- [
          {1, 1},
          {1, 39},
          {layout.transcript.x + 1, 0},
          {layout.transcript.x + 1, 1},
          {layout.composer.x + 1, layout.composer.y + 1}
        ] do
      down = %Mouse{kind: "down", button: "left", x: x, y: y}
      {:noreply, pressed} = App.handle_event(down, state)
      assert pressed.selection.snapshot == nil
      {:noreply, dragged} = App.handle_event(%{down | kind: "up", x: x + 4}, pressed)
      refute dragged.selection.active?
      assert dragged.workspace_form == nil
    end

    state = %{
      state
      | draft: "draft text",
        model: Map.put(state.model, :entries, [%{kind: :assistant, text: "answer text"}])
    }

    {:noreply, selected} = App.handle_event(%Key{code: "a", modifiers: ["ctrl", "shift"]}, state)
    copied = Alto.TUI.Selection.text(selected.selection)
    assert copied =~ "answer text"
    assert copied =~ "draft text"
    refute copied =~ "New workspace"
    refute copied =~ "Composer"
    assert selected.selection.menu == nil

    {:noreply, menu} =
      App.handle_event(%Mouse{kind: "down", button: "right", x: 70, y: 20}, selected)

    assert menu.selection.menu.height == 1
  end

  test "system clipboard and bracketed paste use sanitized draft input from any focus" do
    {:ok, state} =
      App.mount(
        console_module: Console,
        test_mode: {80, 24},
        clipboard_read: fn -> {:ok, "clipboard\e"} end
      )

    {:noreply, state} =
      App.handle_event(%Key{code: "v", modifiers: ["ctrl"]}, %{state | focus: :tasks})

    assert state.draft == "clipboard"
    {:noreply, state} = App.handle_event(%Paste{content: "\nmultiline"}, %{state | focus: :tasks})
    assert state.draft == "clipboard\nmultiline"
    assert state.focus == :composer
    assert state.pending == nil
  end

  test "Escape clears selection before client commands and resize clears stale coordinates" do
    {:ok, state} = App.mount(console_module: Console, test_mode: {80, 24})
    state = %{state | draft: "selectable content"}
    {:noreply, selected} = App.handle_event(%Key{code: "a", modifiers: ["ctrl", "shift"]}, state)
    assert selected.selection.active?
    assert selected.pending == nil
    {:noreply, cleared} = App.handle_event(%Key{code: "esc"}, selected)
    refute cleared.selection.active?
    {:noreply, resized} = App.handle_event(%Resize{width: 50, height: 20}, selected)
    assert resized.dimensions == {50, 20}
    refute resized.selection.active?
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
