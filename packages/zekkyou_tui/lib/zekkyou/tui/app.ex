defmodule Zekkyou.TUI.App do
  @moduledoc "Terminal client for the independently owned Zekkyou service."
  use ExRatatui.App

  alias ExRatatui.Event.{Key, Paste, Resize}
  alias Alto.TUI.{Clipboard, Selection}
  alias ExRatatui.Layout.Rect
  alias Zekkyou.TUI.View

  @impl true
  def mount(opts) do
    console = Keyword.get(opts, :console_module, Zekkyou.Console)
    send(self(), :connect)
    Process.send_after(self(), :poll, 500)

    {:ok,
     %{
       model: console.new(opts),
       console: console,
       draft: "",
       focus: :composer,
       scroll: 0,
       pending: nil,
       submitted_draft: nil,
       dimensions: Keyword.get(opts, :test_mode) || terminal_dimensions(),
       selection: Selection.new(),
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
    view = Map.merge(state.model, %{draft: state.draft, focus: state.focus, scroll: state.scroll})

    Selection.widgets(
      state.selection,
      View.widgets(view, %Rect{width: frame.width, height: frame.height})
    )
  end

  @impl true
  def handle_event(event, state) do
    {width, height} = state.dimensions
    view = Map.merge(state.model, %{draft: state.draft, focus: state.focus, scroll: state.scroll})
    widgets = fn -> View.widgets(view, %Rect{width: width, height: height}) end

    case Selection.event(state.selection, event, state.dimensions, widgets) do
      {:pass, selection} ->
        route_event(event, %{state | selection: selection})

      {:handled, selection} ->
        {:noreply, %{state | selection: selection}}

      {:click, _mouse, selection} ->
        {:noreply, %{state | selection: selection}}

      {:copy, text, selection} ->
        result = state.clipboard_write.(text)

        notice =
          if result == :ok,
            do: "Copied selection",
            else: "Clipboard unavailable; Ctrl+V pastes copy"

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

    scroll = if action == :new or match?({:select, _}, action), do: 0, else: state.scroll

    {:noreply,
     %{state | model: model, draft: draft, pending: nil, submitted_draft: nil, scroll: scroll}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{pending: %Task{ref: ref}} = state) do
    notice =
      "Client operation failed: #{Zekkyou.Console.clean(reason)}; reconnect and inspect before resending"

    {:noreply, %{state | pending: nil, model: Map.put(state.model, :notice, notice)}}
  end

  def handle_info(:connect, state), do: dispatch(state, :connect)

  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, 500)

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
