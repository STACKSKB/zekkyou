defmodule Zekkyou.TUI.ViewTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.{Block, List, Paragraph}
  alias Zekkyou.TUI.View

  @state %{
    tasks: [
      %{id: "one", title: "First task", status: "open"},
      %{id: "two", title: "Second task", status: "done"}
    ],
    selected_id: "two",
    entries: [%{kind: :user, text: "Hello"}, %{kind: :system, text: "Connected"}],
    draft: "",
    detail: "A useful description",
    connection: "connected",
    notice: "Ready",
    scroll: 0
  }

  test "structured returned errors and details render without raw maps" do
    state = %{
      @state
      | entries: [
          %{kind: :error, text: %{message: "Request failed", reason: :eacces}},
          %{kind: :tool, text: ~s({"exit_code":1,"stderr":"Missing file"})}
        ],
        detail: %{request_id: "req-1", status: :failed}
    }

    terminal = ExRatatui.init_test_terminal(150, 42)
    ExRatatui.draw(terminal, View.widgets(state, %Rect{width: 150, height: 42}))
    buffer = ExRatatui.get_buffer_content(terminal)
    assert buffer =~ "Request failed"
    assert buffer =~ "Permission denied"
    assert buffer =~ "Exit code: 1"
    assert buffer =~ "Request id: req-1"
    refute buffer =~ "%{"
    refute buffer =~ "=>"
    literal = ~s(%{example: :source_code})

    state = %{
      @state
      | entries: [%{kind: :user, text: literal}, %{kind: :assistant, text: literal}]
    }

    ExRatatui.draw(terminal, View.widgets(state, %Rect{width: 150, height: 42}))
    assert ExRatatui.get_buffer_content(terminal) =~ literal
  end

  test "renders bounded panes and selects the matching task" do
    viewport = %Rect{x: 3, y: 2, width: 120, height: 36}
    rendered = View.widgets(@state, viewport)

    assert length(rendered) == 8

    assert Enum.all?(rendered, fn {_widget, rect} ->
             rect.x >= viewport.x and rect.y >= viewport.y and
               rect.x + rect.width <= viewport.x + viewport.width and
               rect.y + rect.height <= viewport.y + viewport.height
           end)

    {task_list, _} =
      Enum.find(rendered, fn
        {%List{}, _} -> true
        _ -> false
      end)

    assert task_list.selected == 1

    assert Enum.any?(rendered, fn
             {%ExRatatui.Widgets.Block{title: "Workspaces"}, _} -> true
             _ -> false
           end)

    assert Enum.any?(rendered, fn
             {%Paragraph{text: "+ New workspace · ^G W"}, _} -> true
             _ -> false
           end)
  end

  test "workspace headers group tasks and scrolled hit targets match the displayed rows" do
    projects =
      Enum.map(1..20, fn n ->
        %{"id" => "p#{n}", "name" => "Project #{n}", "root" => "/p#{n}"}
      end)

    state =
      Map.merge(@state, %{
        projects: projects,
        workspace_id: "p20",
        selected_id: "two",
        tasks: [
          %{id: "one", title: "First task", status: "open", workspace_id: "p1"},
          %{id: "two", title: "Second task", status: "done", cwd: "/p20"}
        ]
      })

    rows = View.rail_rows(state)
    assert length(rows) == 21
    assert Enum.at(rows, -1).id == "two"
    assert View.selected_rail_index(state, rows) == 20
    rail = Alto.TUI.Layout.calculate(140, 16).rail
    assert View.rail_target(state, 140, 16, rail.x + 3, rail.y + 1) == :new_workspace
    assert View.rail_target(state, 140, 16, rail.x + 3, rail.y + rail.height - 2).id == "two"
    assert View.rail_target(state, 140, 16, rail.x + 3, rail.y + rail.height - 3).id == "p20"
    terminal = ExRatatui.init_test_terminal(140, 16)
    ExRatatui.draw(terminal, View.widgets(state, %Rect{width: 140, height: 16}))
    screen = ExRatatui.get_buffer_content(terminal)
    assert screen =~ "New workspace"
    assert screen =~ "Project 20"
    assert screen =~ "Second task"
  end

  test "closed workspace tasks stay hidden until their workspace is reopened" do
    project = %{"id" => "p", "name" => "Folder", "root" => "/p", "closed" => true}

    state =
      Map.merge(@state, %{
        projects: [project],
        selected_id: nil,
        workspace_id: nil,
        tasks: [%{id: "t", title: "Saved", status: "running", workspace_id: "p"}]
      })

    assert View.rail_rows(state) == []
    state = %{state | projects: [Map.delete(project, "closed")], workspace_id: "p"}
    assert Enum.map(View.rail_rows(state), & &1.id) == ["p", "t"]
    rail = Alto.TUI.Layout.calculate(140, 40).rail

    assert View.rail_target(state, 140, 40, rail.x + rail.width - 2, rail.y + 2) ==
             {:close_workspace, "p"}
  end

  test "collapses optional panes on narrow terminals" do
    rendered = View.widgets(@state, %Rect{width: 60, height: 12})

    refute Enum.any?(rendered, fn
             {%List{}, _} -> true
             _ -> false
           end)

    assert Enum.count(rendered, fn
             {%Paragraph{block: %Block{title: title}}, _} ->
               String.starts_with?(title, "Conversation")

             _ ->
               false
           end) == 1

    assert Enum.any?(rendered, fn {%Paragraph{text: text}, _} ->
             String.contains?(text, "Type a message")
           end)
  end

  test "handles empty and negative scroll values without mutating state" do
    state = %{tasks: [], entries: [], draft: "", detail: nil, connection: "offline", scroll: -4}
    rendered = View.widgets(state, %Rect{width: 40, height: 8})

    assert state.scroll == -4

    assert Enum.any?(rendered, fn {%Paragraph{text: text}, _} ->
             String.contains?(text, "No messages yet")
           end)
  end
end
