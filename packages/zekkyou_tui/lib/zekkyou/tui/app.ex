defmodule Zekkyou.TUI.App do
  @moduledoc "Terminal client for the independently owned Zekkyou service."
  use ExRatatui.App

  alias ExRatatui.Event.{Key, Paste, Resize}
  alias Alto.TUI.{Clipboard, Selection, WorkspaceForm}
  alias ExRatatui.Layout.Rect
  alias Zekkyou.TUI.View

  @impl true
  def mount(opts) do
    console = Keyword.get(opts, :console_module, Zekkyou.Console)
    send(self(), :connect)
    Process.send_after(self(), :zekkyou_poll, 500)

    {:ok,
     %{
       model: console.new(opts),
       console: console,
       draft: "",
       workspace_form: nil,
       focus: :composer,
       scroll: 0,
       pending: nil,
       submitted_draft: nil,
       dimensions: Keyword.get(opts, :test_mode) || terminal_dimensions(),
       selection: Selection.new(),
       drag_poll: Alto.TUI.DragInput.poller(opts),
       clipboard_text: nil,
       clipboard_write:
         Keyword.get(
           opts,
           :clipboard_write,
           if(opts[:test_mode], do: fn _ -> :ok end, else: &Clipboard.write/1)
         ),
       clipboard_read: Keyword.get(opts, :clipboard_read, &Clipboard.read/0)
     }}
  end

  @impl true
  def render(state, frame) do
    view =
      Map.merge(state.model, %{
        draft: state.draft,
        focus: state.focus,
        scroll: state.scroll,
        workspace_form: state.workspace_form
      })

    Selection.widgets(
      state.selection,
      fn -> View.widgets(view, %Rect{width: frame.width, height: frame.height}) end
    )
  end

  @impl true
  def handle_event(event, state) do
    event = Alto.TUI.DragInput.latest(event, state.drag_poll)
    {width, height} = state.dimensions

    view =
      Map.merge(state.model, %{
        draft: state.draft,
        focus: state.focus,
        scroll: state.scroll,
        workspace_form: state.workspace_form
      })

    widgets = fn -> View.widgets(view, %Rect{width: width, height: height}) end

    case Selection.event(state.selection, event, state.dimensions, widgets,
           content: fn -> View.selection_content(view, width, height) end
         ) do
      {:pass, selection} ->
        route_event(event, %{state | selection: selection})

      {:handled, selection} ->
        {:noreply, %{state | selection: selection}}

      {:click, mouse, selection} ->
        state = %{state | selection: selection}

        if state.workspace_form do
          rect = WorkspaceForm.rect(width, height)

          if Alto.TUI.Layout.contains?(rect, mouse.x, mouse.y),
            do:
              workspace_result(
                state,
                WorkspaceForm.click(
                  state.workspace_form,
                  mouse.y - rect.y - 1,
                  mouse.x - rect.x - 1
                )
              ),
            else: {:noreply, state}
        else
          layout = Alto.TUI.Layout.calculate(width, height)

          if layout.rail && mouse.y == layout.rail.y + 1 &&
               Alto.TUI.Layout.contains?(layout.rail, mouse.x, mouse.y),
             do: open_workspace_form(state),
             else: {:noreply, state}
        end

      {:copy, text, selection} ->
        result = state.clipboard_write.(text)

        notice = Clipboard.notice(result)

        {:noreply,
         %{
           state
           | selection: selection,
             clipboard_text: text,
             model: Map.put(state.model, :notice, notice)
         }}
    end
  end

  defp route_event(%Resize{width: width, height: height}, state),
    do: {:noreply, %{state | dimensions: {width, height}}}

  defp route_event(%Key{kind: "release"}, state), do: {:noreply, state}

  defp route_event(%Key{code: "v", modifiers: ["ctrl"]}, state) do
    content =
      case state.clipboard_read.() do
        {:ok, text} -> text
        _ -> state.clipboard_text
      end

    if content == nil,
      do:
        {:noreply,
         %{
           state
           | model: Map.put(state.model, :notice, "Paste with your terminal's paste shortcut")
         }},
      else: route_event(%Paste{content: content}, state)
  end

  defp route_event(%Key{} = event, %{workspace_form: form} = state) when not is_nil(form),
    do: workspace_result(state, WorkspaceForm.key(form, event))

  defp route_event(%Key{code: "f7"}, state), do: open_workspace_form(state)

  defp route_event(%Paste{content: text}, %{workspace_form: form} = state) when not is_nil(form),
    do: {:noreply, %{state | workspace_form: WorkspaceForm.paste(form, text)}}

  defp route_event(%Key{} = event, state), do: key(event, state)

  defp route_event(%Paste{content: text}, state),
    do: {:noreply, append_draft(%{state | focus: :composer, selection: Selection.new()}, text)}

  defp route_event(_event, state), do: {:noreply, state}

  defp key(%Key{code: code, modifiers: mods}, state) do
    cond do
      "ctrl" in mods and code in ["q", "c"] ->
        {:stop, state}

      "ctrl" in mods and code in ["k", "a", "d", "r", "n"] ->
        dispatch(
          state,
          %{"k" => :cancel, "a" => :approve, "d" => :deny, "r" => :connect, "n" => :new}[code]
        )

      "ctrl" in mods or "alt" in mods or "super" in mods ->
        {:noreply, state}

      code == "tab" ->
        {:noreply, %{state | focus: next_focus(state.focus)}}

      code in ["page_up", "page_down"] ->
        offset = if code == "page_up", do: -10, else: 10
        {:noreply, %{state | scroll: max(0, state.scroll + offset)}}

      code in ["up", "down"] and state.focus == :tasks ->
        select_task(state, code)

      code == "enter" and state.focus == :composer ->
        dispatch(state, composer_action(state, state.draft))

      code == "backspace" and state.focus == :composer ->
        {:noreply,
         %{state | draft: String.slice(state.draft, 0, max(0, String.length(state.draft) - 1))}}

      state.focus == :composer and is_binary(code) and String.length(code) == 1 ->
        {:noreply, append_draft(state, code)}

      true ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:tui_deferred_input, event}, state), do: handle_event(event, state)

  def handle_info({ref, {model, action}}, %{pending: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    draft =
      case action do
        {:submit, submitted} when submitted == state.draft ->
          if model.notice == "Sent" or String.starts_with?(model.notice, "Sent;"),
            do: "",
            else: state.draft

        {:reconcile, _resolution, _note} ->
          if model.notice == "Decision recorded" and state.submitted_draft == state.draft,
            do: "",
            else: state.draft

        _ ->
          state.draft
      end

    approval_changed? = View.approval_key(state.model) != View.approval_key(model)

    scroll =
      if approval_changed? or action == :new or match?({:workspace, _}, action) or
           match?({:select, _}, action),
         do: 0,
         else: state.scroll

    form =
      if match?({:workspace, _}, action) and state.workspace_form do
        if String.starts_with?(model.notice, "Workspace opened:"),
          do: nil,
          else: %{state.workspace_form | error: model.notice}
      else
        state.workspace_form
      end

    {:noreply,
     %{
       state
       | model: model,
         draft: draft,
         pending: nil,
         submitted_draft: nil,
         scroll: scroll,
         selection: if(approval_changed?, do: Selection.new(), else: state.selection),
         workspace_form: form,
         focus:
           cond do
             approval_changed? and View.approval(model) != nil -> :composer
             match?({:workspace, _}, action) and is_nil(form) -> :composer
             true -> state.focus
           end
     }}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{pending: %Task{ref: ref}} = state) do
    notice =
      "Client operation failed: #{Zekkyou.Console.clean(reason)}; reconnect and inspect before resending"

    {:noreply, %{state | pending: nil, model: Map.put(state.model, :notice, notice)}}
  end

  def handle_info(:connect, state), do: dispatch(state, :connect)

  def handle_info(:zekkyou_poll, state) do
    Process.send_after(self(), :zekkyou_poll, 500)

    if state.pending || state.model.client == nil,
      do: {:noreply, state},
      else: dispatch(state, :poll)
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.pending, do: Task.shutdown(state.pending, :brutal_kill)
    state.console.close(state.model)
  end

  defp dispatch(%{pending: pending} = state, _action) when not is_nil(pending),
    do: {:noreply, %{state | model: Map.put(state.model, :notice, "Waiting for the service…")}}

  defp dispatch(state, action) do
    owner = self()

    task =
      Task.Supervisor.async_nolink(Alto.TaskSupervisor, fn ->
        {state.console.perform(state.model, action, owner), action}
      end)

    submitted_draft =
      if match?({:submit, _}, action) or match?({:reconcile, _, _}, action),
        do: state.draft,
        else: nil

    {:noreply, %{state | pending: task, submitted_draft: submitted_draft}}
  end

  defp open_workspace_form(state) do
    base = Map.get(state.model, :workspace_base) || "the service's default workspace"

    {:noreply,
     %{
       state
       | workspace_form:
           WorkspaceForm.new(
             base,
             "the service host",
             Enum.map(Map.get(state.model, :projects, []), & &1["root"])
           )
     }}
  end

  defp workspace_result(state, :cancel), do: {:noreply, %{state | workspace_form: nil}}
  defp workspace_result(state, {:edit, form}), do: {:noreply, %{state | workspace_form: form}}
  defp workspace_result(state, {:submit, path}), do: dispatch(state, {:workspace, path})

  defp terminal_dimensions do
    case ExRatatui.terminal_size() do
      {width, height} when is_integer(width) and is_integer(height) -> {width, height}
      _ -> {120, 36}
    end
  end

  defp next_focus(:composer), do: :tasks
  defp next_focus(:tasks), do: :composer

  defp select_task(state, direction) do
    ids = Enum.map(state.model.tasks, & &1.id)
    current = Enum.find_index(ids, &(&1 == state.model.selected_id))

    index =
      if is_nil(current),
        do: 0,
        else: max(0, min(length(ids) - 1, current + if(direction == "up", do: -1, else: 1)))

    case Enum.at(ids, index) do
      nil -> {:noreply, state}
      id -> dispatch(state, {:select, id})
    end
  end

  defp append_draft(state, text) do
    text = Zekkyou.Console.clean_input(text)
    available = max(0, 32_000 - byte_size(state.draft))

    text =
      if byte_size(text) <= available,
        do: text,
        else: text |> binary_part(0, available) |> valid_prefix()

    %{state | draft: state.draft <> text}
  end

  defp composer_action(state, text) do
    case Enum.find(state.model.tasks, &(&1.id == state.model.selected_id)) do
      %{status: "requires_operator"} ->
        case Regex.run(~r/\A\/(retry|committed|failed) (\S(?:.*\S)?)\z/s, text,
               capture: :all_but_first
             ) do
          [resolution, note] -> {:reconcile, resolution, note}
          _ -> {:submit, text}
        end

      _ ->
        {:submit, text}
    end
  end

  defp valid_prefix(text) do
    if String.valid?(text),
      do: text,
      else: valid_prefix(binary_part(text, 0, byte_size(text) - 1))
  end
end
