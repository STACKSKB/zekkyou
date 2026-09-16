defmodule Zekkyou.TUI.View do
  @moduledoc """
  Pure view layer for the optional Zekkyou terminal interface.

  The view deliberately only turns a state map into ExRatatui widgets.  It
  performs no I/O, which makes it useful both to the controller and to tests.
  """

  alias Alto.TUI.{Layout, WorkspaceForm}
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.{Block, List, Paragraph, Popup}

  @doc "Workspace headers and task rows in their displayed order."
  def rail_rows(state) do
    projects = Map.get(state, :projects, [])
    tasks = Map.get(state, :tasks, [])
    active = active_project_id(state)

    rows =
      Enum.flat_map(Enum.reject(projects, &(&1["closed"] == true)), fn project ->
        expanded? = project["id"] == active

        header = %{
          kind: :project,
          id: project["id"],
          label: if(expanded?, do: "▾ ", else: "▸ ") <> project["name"]
        }

        children =
          if expanded?,
            do: Enum.filter(tasks, &(task_project_id(&1, projects) == project["id"])),
            else: []

        [header | Enum.map(children, &task_row(&1, "  "))]
      end)

    # Retain legacy/service tasks without a registered workspace.
    rows ++
      (tasks
       |> Enum.filter(&is_nil(task_project_id(&1, projects)))
       |> Enum.map(&task_row(&1, "")))
  end

  def selected_rail_index(state, rows) do
    target =
      if Map.get(state, :selected_id),
        do: {:task, state.selected_id},
        else: {:project, active_project_id(state)}

    Enum.find_index(rows, &({&1.kind, &1.id} == target))
  end

  def rail_target(state, width, height, x, y) do
    rail = Layout.calculate(width, height).rail

    if Layout.contains?(rail, x, y) do
      visible = max(rail.height - 3, 0)
      rows = rail_rows(state)
      offset = max((selected_rail_index(state, rows) || 0) - visible + 1, 0)
      row = y - rail.y - 2

      cond do
        y == rail.y + 1 ->
          :new_workspace

        row >= 0 and row < visible ->
          case Enum.at(rows, row + offset) do
            %{kind: :project, id: id} when x == rail.x + rail.width - 2 -> {:close_workspace, id}
            row -> row
          end

        true ->
          nil
      end
    end
  end

  def active_project_id(state) do
    projects = Map.get(state, :projects, [])
    task = Enum.find(Map.get(state, :tasks, []), &(&1.id == Map.get(state, :selected_id)))

    (task && task_project_id(task, projects)) || Map.get(state, :workspace_id) ||
      Enum.find_value(projects, fn p ->
        if p["root"] == Map.get(state, :workspace_root), do: p["id"]
      end)
  end

  defp task_project_id(task, projects) do
    Enum.find_value(projects, fn p ->
      if p["id"] == Map.get(task, :workspace_id) or p["root"] == Map.get(task, :cwd), do: p["id"]
    end)
  end

  defp close_workspace_buttons(rows, selected, rect, inner) do
    offset = max((selected || 0) - inner.height + 1, 0)

    rows
    |> Enum.drop(offset)
    |> Enum.take(inner.height)
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {%{kind: :project}, row} ->
        [
          {%Paragraph{text: "×"},
           %Rect{x: rect.x + rect.width - 2, y: inner.y + row, width: 1, height: 1}}
        ]

      _ ->
        []
    end)
  end

  defp task_row(task, indent), do: %{kind: :task, id: task.id, label: indent <> task_label(task)}

  @type state :: map()
  @type rendered :: {ExRatatui.widget(), Rect.t()}

  @doc "Build all widgets and their screen rectangles for one frame."
  @spec widgets(state(), Rect.t()) :: [rendered()]
  def widgets(state, %Rect{} = viewport) when is_map(state) do
    geometry = Layout.calculate(viewport.width, viewport.height)
    geometry = translate(geometry, viewport.x, viewport.y)

    rows = rail_rows(state)
    task_items = Enum.map(rows, & &1.label)
    selected = selected_rail_index(state, rows)

    rail =
      if geometry.rail do
        list = %List{
          items: task_items,
          selected: selected,
          highlight_symbol: "› ",
          block: nil
        }

        rect = geometry.rail

        inner = %Rect{
          x: rect.x + 1,
          y: rect.y + 2,
          width: max(rect.width - 2, 0),
          height: max(rect.height - 3, 0)
        }

        [
          {panel(if(Map.get(state, :focus) == :tasks, do: "Workspaces •", else: "Workspaces")),
           rect},
          {%Paragraph{text: "+ New workspace · ^G W"}, %{inner | y: rect.y + 1, height: 1}},
          {list, %{inner | width: max(inner.width - 2, 0)}}
        ] ++ close_workspace_buttons(rows, selected, rect, inner)
      else
        []
      end

    transcript = %Paragraph{
      text: conversation_text(state, geometry),
      wrap: true,
      scroll:
        {min(
           max(Map.get(state, :scroll, 0), 0),
           scroll_bottom(state, viewport.width, viewport.height)
         ), 0},
      block: panel("Conversation • " <> selected_title(state))
    }

    settings =
      if geometry.settings.height > 0 do
        notice = Map.get(state, :notice, "") |> to_string_or_empty()

        [
          {%Paragraph{text: effort_setting(state) <> if(notice == "", do: " ", else: notice)},
           geometry.settings}
        ]
      else
        []
      end

    composer_text =
      case Map.get(state, :draft, "") |> to_string_or_empty() do
        "" -> "Type a message, then press Enter to send."
        draft -> draft
      end

    composer = %Paragraph{
      text: composer_text,
      wrap: true,
      block:
        panel(
          if(Map.get(state, :focus, :composer) == :composer, do: "Composer •", else: "Composer")
        )
    }

    details =
      if geometry.details do
        detail = detail_text(state)

        [
          {%Paragraph{
             text: if(detail == "", do: "No task selected.", else: detail),
             wrap: true,
             scroll:
               {min(
                  max(Map.get(state, :details_scroll, 0), 0),
                  details_bottom(state, viewport.width, viewport.height)
                ), 0},
             block: panel(if(approval(state), do: "Approval required", else: "Details"))
           }, geometry.details}
        ]
      else
        []
      end

    status = %Paragraph{
      text: status_text(state)
    }

    center =
      if geometry.rail == nil and Map.get(state, :focus) == :tasks,
        do: %List{
          items: task_items,
          selected: selected,
          highlight_symbol: "› ",
          block: panel("Tasks • Tab to compose")
        },
        else: transcript

    widgets =
      rail ++
        [{center, geometry.transcript}] ++
        settings ++ [{composer, geometry.composer}] ++ details ++ [{status, geometry.status}]

    case Map.get(state, :workspace_form) do
      nil -> widgets ++ effort_widgets(state, viewport)
      form -> widgets ++ WorkspaceForm.widgets(form, viewport)
    end
  end

  defp effort_setting(state) do
    if Map.get(state, :effort_catalog),
      do: "Effort #{Map.get(state, :selected_effort) || "default"} · ^G E  ",
      else: ""
  end

  defp effort_widgets(%{effort_picker: %{choices: choices, index: index}}, viewport) do
    title =
      if length(choices) == 1,
        do: "Effort not advertised · Esc close",
        else: "Reasoning effort · ↑↓ Enter · Esc"

    text =
      choices
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {value, i} ->
        if(i == index, do: "› ", else: "  ") <> (value || "Provider default")
      end)

    [
      {%Popup{
         content: %Paragraph{text: text},
         block: panel(title),
         fixed_width: min(52, viewport.width),
         fixed_height: min(length(choices) + 2, viewport.height)
       }, viewport}
    ]
  end

  defp effort_widgets(_, _), do: []

  def scroll_bottom(state, width, height) do
    geometry = Layout.calculate(width, height)
    rect = geometry.transcript

    Alto.TUI.Scroll.bottom(
      conversation_text(state, geometry),
      rect.width - 2,
      rect.height - 2,
      :zekkyou_transcript
    )
  end

  def details_bottom(state, width, height) do
    case Layout.calculate(width, height).details do
      nil ->
        0

      rect ->
        Alto.TUI.Scroll.bottom(
          detail_text(state),
          rect.width - 2,
          rect.height - 2,
          :zekkyou_details
        )
    end
  end

  @doc "Selectable task content; chrome and empty-field hints are opt-in via Alt+drag."
  def selection_content(%{effort_picker: picker}, _, _) when not is_nil(picker), do: []

  def selection_content(%{workspace_form: form}, width, height) when not is_nil(form),
    do: WorkspaceForm.selection_content(form, width, height)

  def selection_content(state, width, height) do
    layout = Layout.calculate(width, height)
    detail? = approval(state) != nil or Map.get(state, :detail, "") not in [nil, ""]
    tasks? = layout.rail == nil and Map.get(state, :focus) == :tasks

    transcript =
      if not tasks? and
           (Map.get(state, :entries, []) != [] or (layout.details == nil and detail?)),
         do: [content_rect(layout.transcript)],
         else: []

    composer =
      if Map.get(state, :draft, "") in [nil, ""], do: [], else: [content_rect(layout.composer)]

    details = if layout.details && detail?, do: [content_rect(layout.details)], else: []
    transcript ++ composer ++ details
  end

  defp content_rect(rect),
    do: %Rect{
      x: rect.x + 1,
      y: rect.y + 1,
      width: max(rect.width - 2, 0),
      height: max(rect.height - 2, 0)
    }

  defp conversation_text(state, geometry) do
    transcript = transcript_text(Map.get(state, :entries, []))

    text =
      if geometry.details == nil and approval(state),
        do: "Approval required\n\n" <> detail_text(state) <> "\n\n" <> transcript,
        else: transcript <> compact_detail(state, geometry)

    if String.trim(text) == "",
      do: "No messages yet. Start a conversation with the composer below.",
      else: text
  end

  defp selected_title(state) do
    case Enum.find(Map.get(state, :tasks, []), &(&1.id == Map.get(state, :selected_id))) do
      nil -> "New task"
      task -> String.slice(task.title, 0, 40)
    end
  end

  defp compact_detail(state, %{details: nil}) do
    "\n\n" <> detail_text(state)
  end

  defp compact_detail(_state, _geometry), do: ""

  # Workspace commands already live in the task rail and status bar. Keep the
  # context body as data so ordinary selection does not copy those controls.
  defp detail_text(state) do
    case approval(state) do
      nil -> ordinary_detail(state)
      request -> Alto.TUI.ApprovalView.text(request)
    end
  end

  @doc "The same authoritative approval snapshot that the console's decision targets."
  def approval(state) do
    task =
      Enum.find(Map.get(state, :tasks, []), &(Map.get(&1, :id) == Map.get(state, :selected_id)))

    case task do
      %{upgrade_required: reason} when is_binary(reason) ->
        nil

      %{status: "waiting_approval", approval: request} when is_map(request) ->
        request

      %{run_id: run} when not is_nil(run) ->
        state
        |> Map.get(:approvals, %{})
        |> Map.values()
        |> Enum.filter(&(Map.get(&1, "run_id") == run))
        |> Enum.sort_by(&Map.get(&1, "id"))
        |> Elixir.List.first()

      _ ->
        nil
    end
  end

  def approval_key(state) do
    case approval(state) do
      nil -> nil
      request -> Map.get(request, "id") || Map.get(request, :id) || request
    end
  end

  defp ordinary_detail(state) do
    detail = Map.get(state, :detail, "") |> to_string_or_empty()

    case detail do
      "Workspace folder\n" <> rest ->
        case Regex.split(~r/\n(?:F7 New workspace|\^G W Change folder)\n\n/, rest, parts: 2) do
          [folder, data] -> folder <> "\n\n" <> data
          _ -> detail
        end

      _ ->
        detail
    end
  end

  defp panel(title), do: %Block{title: title, borders: [:all], border_type: :rounded}

  defp task_label(task) do
    status = task |> Map.get(:status, "") |> to_string_or_empty()
    title = task |> Map.get(:title, "Untitled task") |> to_string_or_empty()
    if status == "", do: title, else: "#{status}  #{title}"
  end

  defp transcript_text([]), do: ""

  defp transcript_text(entries) do
    entries
    |> Enum.map(fn entry ->
      kind = entry |> Map.get(:kind, :message) |> to_string_or_empty() |> String.upcase()
      value = Map.get(entry, :text, "")

      text =
        case kind do
          "ERROR" -> Alto.Display.error(value)
          role when role in ["TOOL", "ACTIVITY"] -> Alto.Display.result(value)
          _ -> to_string_or_empty(value)
        end

      "#{if kind == "REASONING", do: "THINKING", else: kind}: #{text}"
    end)
    |> Enum.join("\n")
  end

  defp status_text(%{leader?: true}),
    do:
      " Gear: N new task · W folder · X close workspace · E effort · T tasks · A approve · D deny · K cancel · R reconnect · Q quit · Esc cancel"

  defp status_text(state) do
    connection = state |> Map.get(:connection, "offline") |> to_string_or_empty()

    " #{connection} | ^G gear · N new task · W folder · X close workspace · E effort ^Q quit ^R reconnect ^N new task Tab focus ^K cancel ^A approve ^D deny Enter send"
  end

  defp to_string_or_empty(value) when is_binary(value), do: value
  defp to_string_or_empty(nil), do: ""
  defp to_string_or_empty(value), do: Alto.Display.text(value)

  defp translate(geometry, dx, dy) do
    Map.new(geometry, fn
      {key, %Rect{} = rect} -> {key, shift(rect, dx, dy)}
      {key, nil} -> {key, nil}
      pair -> pair
    end)
  end

  defp shift(%Rect{} = rect, dx, dy), do: %{rect | x: rect.x + dx, y: rect.y + dy}
end
