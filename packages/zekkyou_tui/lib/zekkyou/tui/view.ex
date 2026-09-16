defmodule Zekkyou.TUI.View do
  @moduledoc """
  Pure view layer for the optional Zekkyou terminal interface.

  The view deliberately only turns a state map into ExRatatui widgets.  It
  performs no I/O, which makes it useful both to the controller and to tests.
  """

  alias Alto.TUI.{Layout, WorkspaceForm}
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.{Block, List, Paragraph}

  @type state :: map()
  @type rendered :: {ExRatatui.widget(), Rect.t()}

  @doc "Build all widgets and their screen rectangles for one frame."
  @spec widgets(state(), Rect.t()) :: [rendered()]
  def widgets(state, %Rect{} = viewport) when is_map(state) do
    geometry = Layout.calculate(viewport.width, viewport.height)
    geometry = translate(geometry, viewport.x, viewport.y)

    tasks = Map.get(state, :tasks, [])
    selected_id = Map.get(state, :selected_id)
    task_items = Enum.map(tasks, &task_label/1)
    selected = Enum.find_index(tasks, &(Map.get(&1, :id) == selected_id))

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
          {panel(if(Map.get(state, :focus) == :tasks, do: "Tasks •", else: "Tasks")), rect},
          {%Paragraph{text: "+ New task · ^G N"}, %{inner | y: rect.y + 1, height: 1}},
          {list, inner}
        ]
      else
        []
      end

    transcript = %Paragraph{
      text: conversation_text(state, geometry),
      wrap: true,
      scroll: {max(Map.get(state, :scroll, 0), 0), 0},
      block: panel("Conversation • " <> selected_title(state))
    }

    settings =
      if geometry.settings.height > 0 do
        notice = Map.get(state, :notice, "") |> to_string_or_empty()

        [
          {%Paragraph{text: if(notice == "", do: " ", else: notice)}, geometry.settings}
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
      nil -> widgets
      form -> widgets ++ WorkspaceForm.widgets(form, viewport)
    end
  end

  @doc "Selectable task content; chrome and empty-field hints are opt-in via Alt+drag."
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
        case String.split(rest, "\nF7 New workspace\n\n", parts: 2) do
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
      text = entry |> Map.get(:text, "") |> to_string_or_empty()
      "#{kind}: #{text}"
    end)
    |> Enum.join("\n")
  end

  defp status_text(%{leader?: true}),
    do:
      " Gear: N new task · W folder · T tasks · A approve · D deny · K cancel · R reconnect · Q quit · Esc cancel"

  defp status_text(state) do
    connection = state |> Map.get(:connection, "offline") |> to_string_or_empty()

    " #{connection} | ^G gear · N new task · W folder ^Q quit ^R reconnect ^N new task Tab focus ^K cancel ^A approve ^D deny Enter send"
  end

  defp to_string_or_empty(value) when is_binary(value), do: value
  defp to_string_or_empty(nil), do: ""
  defp to_string_or_empty(value), do: to_string(value)

  defp translate(geometry, dx, dy) do
    Map.new(geometry, fn
      {key, %Rect{} = rect} -> {key, shift(rect, dx, dy)}
      {key, nil} -> {key, nil}
      pair -> pair
    end)
  end

  defp shift(%Rect{} = rect, dx, dy), do: %{rect | x: rect.x + dx, y: rect.y + dy}
end
