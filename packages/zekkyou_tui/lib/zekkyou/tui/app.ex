defmodule Zekkyou.TUI.App do
  @moduledoc "Terminal client for the independently owned Zekkyou service."
  use ExRatatui.App

  alias ExRatatui.Event.{Key, Mouse, Paste, Resize}
  alias Alto.TUI.{Clipboard, Selection, WorkspaceForm}
  alias ExRatatui.Layout.Rect
  alias Zekkyou.TUI.View

  @impl true
  def mount(opts) do
    console = Keyword.get(opts, :console_module, Zekkyou.Console)
    send(self(), :connect)
    Process.send_after(self(), :zekkyou_poll, 500)
    Process.send_after(self(), :tui_activity_tick, 250)

    {:ok,
     %{
       model: console.new(opts),
       console: console,
       draft: "",
       workspace_form: nil,
       effort_picker: nil,
       leader?: false,
       focus: :composer,
       scroll: 0,
       details_scroll: 0,
       pending: nil,
       pending_action: :connect,
       pending_started_ms: System.system_time(:millisecond),
       activity_tick: 0,
       activity_started_ms: System.system_time(:millisecond),
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
        details_scroll: state.details_scroll,
        workspace_form: state.workspace_form,
        effort_picker: state.effort_picker,
        leader?: state.leader?
      })

    Selection.widgets(
      state.selection,
      fn -> View.widgets(view, %Rect{width: frame.width, height: frame.height}) end
    ) ++ activity_widgets(state, frame)
  end

  defp activity_widgets(state, frame) do
    rect = Alto.TUI.Layout.calculate(frame.width, frame.height).transcript

    Alto.TUI.Activity.widgets(
      activity_label(state),
      state.activity_started_ms,
      state.activity_tick,
      rect
    )
  end

  defp activity_label(state) do
    task = Enum.find(Map.get(state.model, :tasks, []), &(&1.id == state.model.selected_id))

    cond do
      state.pending_action == :connect ->
        "waiting for connection"

      match?({:submit, _}, state.pending_action) ->
        "sending message"

      state.pending != nil and state.pending_action != :poll ->
        "waiting for service"

      task &&
          task.status in [
            "running",
            "waiting",
            "waiting_approval",
            "queued",
            "claimed",
            "awaiting_admission"
          ] ->
        fallback =
          if task.status == "waiting_approval",
            do: "waiting for approval",
            else: "waiting for model"

        event = Map.get(Map.get(state.model, :live, %{}), Map.get(task, :run_id))
        Alto.TUI.Activity.phase(event, fallback)

      state.pending != nil and System.system_time(:millisecond) - state.pending_started_ms > 1500 ->
        "waiting for service"

      true ->
        nil
    end
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
        details_scroll: state.details_scroll,
        workspace_form: state.workspace_form,
        effort_picker: state.effort_picker,
        leader?: state.leader?
      })

    widgets = fn -> View.widgets(view, %Rect{width: width, height: height}) end

    case Selection.event(state.selection, event, state.dimensions, widgets,
           content: fn -> View.selection_content(view, width, height) end,
           scroll_limit: fn point ->
             case selection_pane(state, point) do
               :transcript -> View.scroll_bottom(view, width, height)
               :details -> View.details_bottom(view, width, height)
               _ -> nil
             end
           end
         ) do
      {:pass, selection} ->
        route_event(event, %{state | selection: selection})

      {:handled, selection} ->
        {:noreply, apply_selection_scroll(state, selection)}

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
                  mouse.x - rect.x - 1,
                  rect.height
                )
              ),
            else: {:noreply, state}
        else
          layout = Alto.TUI.Layout.calculate(width, height)

          case View.rail_target(state.model, width, height, mouse.x, mouse.y) do
            :new_workspace ->
              open_workspace_form(state)

            {:close_workspace, id} ->
              dispatch(state, {:close_workspace, id})

            %{kind: :project, id: id} ->
              dispatch(%{state | focus: :composer}, {:select_workspace, id})

            %{kind: :task, id: id} ->
              dispatch(%{state | focus: :tasks}, {:select, id})

            _ ->
              if Alto.TUI.Layout.contains?(layout.details, mouse.x, mouse.y),
                do: {:noreply, %{state | focus: :details}},
                else: {:noreply, state}
          end
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

  defp selection_pane(%{effort_picker: picker}, _) when not is_nil(picker), do: nil

  defp selection_pane(%{workspace_form: form}, _) when not is_nil(form), do: nil

  defp selection_pane(state, {x, y}) do
    {width, height} = state.dimensions
    layout = Alto.TUI.Layout.calculate(width, height)

    cond do
      Alto.TUI.Layout.contains?(layout.details, x, y) -> :details
      Alto.TUI.Layout.contains?(layout.transcript, x, y) -> :transcript
      true -> nil
    end
  end

  defp apply_selection_scroll(state, selection) do
    state = %{state | selection: selection}

    case Selection.scroll_position(selection) do
      {point, offset} ->
        case selection_pane(state, point) do
          :transcript -> %{state | scroll: offset}
          :details -> %{state | details_scroll: offset}
          _ -> state
        end

      nil ->
        state
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

  defp route_event(%Key{code: code}, %{effort_picker: picker} = state) when not is_nil(picker) do
    case code do
      "esc" ->
        {:noreply, %{state | effort_picker: nil}}

      "up" ->
        {:noreply, %{state | effort_picker: %{picker | index: max(picker.index - 1, 0)}}}

      "down" ->
        {:noreply,
         %{
           state
           | effort_picker: %{picker | index: min(picker.index + 1, length(picker.choices) - 1)}
         }}

      "enter" ->
        dispatch(%{state | effort_picker: nil}, {:effort, Enum.at(picker.choices, picker.index)})

      _ ->
        {:noreply, state}
    end
  end

  defp route_event(%Key{} = event, %{workspace_form: form} = state) when not is_nil(form),
    do: workspace_result(state, WorkspaceForm.key(form, event))

  defp route_event(%Key{code: "g", modifiers: ["ctrl"]}, state),
    do: {:noreply, %{state | leader?: not state.leader?}}

  defp route_event(%Key{code: code}, %{leader?: true} = state) do
    state = %{state | leader?: false}

    case String.downcase(code || "") do
      "e" -> dispatch(state, :efforts)
      "w" -> open_workspace_form(state)
      "x" -> dispatch(state, {:close_workspace, View.active_project_id(state.model)})
      "n" -> dispatch(%{state | focus: :composer}, :new)
      "t" -> {:noreply, %{state | focus: :tasks}}
      "a" -> dispatch(state, :approve)
      "d" -> dispatch(state, :deny)
      "k" -> dispatch(state, :cancel)
      "r" -> dispatch(state, :connect)
      "q" -> {:stop, state}
      _ -> {:noreply, state}
    end
  end

  defp route_event(%Paste{content: text}, %{workspace_form: form} = state) when not is_nil(form),
    do: workspace_result(state, {:edit, WorkspaceForm.paste(form, text)})

  defp route_event(%Key{} = event, state), do: key(event, state)

  defp route_event(%Paste{content: text}, state),
    do: {:noreply, append_draft(%{state | focus: :composer, selection: Selection.new()}, text)}

  defp route_event(%Mouse{kind: kind, x: x, y: y}, %{workspace_form: nil} = state)
       when kind in ["scroll_up", "scroll_down"] do
    {width, height} = state.dimensions
    layout = Alto.TUI.Layout.calculate(width, height)
    delta = if kind == "scroll_up", do: -3, else: 3

    cond do
      Alto.TUI.Layout.contains?(layout.details, x, y) ->
        {:noreply, scroll(state, :details, delta)}

      Alto.TUI.Layout.contains?(layout.transcript, x, y) ->
        {:noreply, scroll(state, :transcript, delta)}

      true ->
        {:noreply, state}
    end
  end

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
        {:noreply, scroll(state, state.focus, offset)}

      code in ["up", "down"] and state.focus == :tasks ->
        select_rail(state, code)

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
  def handle_info(
        {:complete_workspace, revision},
        %{workspace_form: %{revision: revision} = form} = state
      ) do
    owner = self()
    path = WorkspaceForm.path(form)

    Task.start(fn ->
      result = state.console.complete_folders(state.model, path)
      send(owner, {:workspace_suggestions, revision, result})
    end)

    {:noreply, state}
  end

  def handle_info({:complete_workspace, _revision}, state), do: {:noreply, state}

  def handle_info(
        {:workspace_suggestions, revision, result},
        %{workspace_form: %{revision: revision} = form} = state
      ),
      do: workspace_result(state, {:edit, WorkspaceForm.suggest(form, result)})

  def handle_info({:workspace_suggestions, _revision, _result}, state), do: {:noreply, state}

  def handle_info({:tui_deferred_input, event}, state), do: handle_event(event, state)

  def handle_info(:tui_activity_tick, state) do
    Process.send_after(self(), :tui_activity_tick, 250)
    next = %{state | activity_tick: state.activity_tick + 1}
    {:noreply, next, render?: activity_label(state) != nil}
  end

  def handle_info({:tui_selection_scroll, token}, state) do
    case Selection.autoscroll(state.selection, token) do
      {:scrolled, selection} -> {:noreply, apply_selection_scroll(state, selection)}
      {:idle, selection} -> {:noreply, %{state | selection: selection}, render?: false}
    end
  end

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
           match?({:select, _}, action) or
           match?({:select_workspace, _}, action) or match?({:close_workspace, _}, action),
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
         effort_picker:
           if(action == :efforts and Map.get(model, :effort_catalog),
             do: %{choices: [nil | model.effort_catalog["efforts"]], index: 0},
             else: state.effort_picker
           ),
         draft: draft,
         pending: nil,
         pending_action: nil,
         submitted_draft: nil,
         scroll: scroll,
         details_scroll:
           if(
             approval_changed? or action == :new or
               match?({:select, _}, action) or
               match?({:select_workspace, _}, action) or match?({:close_workspace, _}, action) or
               match?({:workspace, _}, action),
             do: 0,
             else: state.details_scroll
           ),
         selection: if(approval_changed?, do: Selection.new(), else: state.selection),
         workspace_form: form,
         focus:
           cond do
             approval_changed? and View.approval(model) != nil ->
               :composer

             match?({:workspace, _}, action) and is_nil(form) ->
               :composer

             match?({:close_workspace, _}, action) and
                 View.active_project_id(state.model) != View.active_project_id(model) ->
               :composer

             true ->
               state.focus
           end
     }}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{pending: %Task{ref: ref}} = state) do
    notice =
      "Client operation failed: #{Alto.Display.error(reason)}; reconnect and inspect before resending"

    {:noreply,
     %{state | pending: nil, pending_action: nil, model: Map.put(state.model, :notice, notice)}}
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

    {:noreply,
     %{
       state
       | pending: task,
         pending_action: action,
         pending_started_ms: System.system_time(:millisecond),
         submitted_draft: submitted_draft,
         activity_started_ms:
           if(action == :poll,
             do: state.activity_started_ms,
             else: System.system_time(:millisecond)
           )
     }}
  end

  defp open_workspace_form(state) do
    base = Map.get(state.model, :workspace_base) || "the service's default workspace"

    form =
      WorkspaceForm.new(
        base,
        "the service host",
        Enum.map(Map.get(state.model, :projects, []), & &1["root"]),
        complete: nil
      )

    workspace_result(state, {:edit, form})
  end

  defp workspace_result(state, :cancel), do: {:noreply, %{state | workspace_form: nil}}

  defp workspace_result(state, {:edit, form}) do
    if Code.ensure_loaded?(state.console) and
         function_exported?(state.console, :complete_folders, 2) and
         (state.workspace_form == nil or state.workspace_form.revision != form.revision) do
      Process.send_after(self(), {:complete_workspace, form.revision}, 40)
    end

    {:noreply, %{state | workspace_form: form}}
  end

  defp workspace_result(state, {:submit, path}), do: dispatch(state, {:workspace, path})

  defp terminal_dimensions do
    case ExRatatui.terminal_size() do
      {width, height} when is_integer(width) and is_integer(height) -> {width, height}
      _ -> {120, 36}
    end
  end

  defp scroll(state, :details, delta) do
    {w, h} = state.dimensions

    %{
      state
      | details_scroll:
          min(max(state.details_scroll + delta, 0), View.details_bottom(state.model, w, h))
    }
  end

  defp scroll(state, _, delta) do
    {w, h} = state.dimensions
    %{state | scroll: min(max(state.scroll + delta, 0), View.scroll_bottom(state.model, w, h))}
  end

  defp next_focus(:details), do: :composer
  defp next_focus(:composer), do: :tasks
  defp next_focus(:tasks), do: :composer

  defp select_rail(state, direction) do
    rows = View.rail_rows(state.model)
    current = View.selected_rail_index(state.model, rows)

    index =
      if is_nil(current),
        do: 0,
        else: max(0, min(length(rows) - 1, current + if(direction == "up", do: -1, else: 1)))

    case Enum.at(rows, index) do
      %{kind: :project, id: id} -> dispatch(state, {:select_workspace, id})
      %{kind: :task, id: id} -> dispatch(state, {:select, id})
      _ -> {:noreply, state}
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
