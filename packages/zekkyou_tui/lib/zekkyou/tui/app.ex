defmodule Zekkyou.TUI.App do
  @moduledoc "Terminal client for the independently owned Zekkyou service."
  use ExRatatui.App

  alias ExRatatui.Event.{Key, Paste}
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
       submitted_draft: nil
     }}
  end

  @impl true
  def render(state, frame) do
    view = Map.merge(state.model, %{draft: state.draft, focus: state.focus, scroll: state.scroll})
    View.widgets(view, %Rect{width: frame.width, height: frame.height})
  end

  @impl true
  def handle_event(%Key{kind: "release"}, state), do: {:noreply, state}
  def handle_event(%Key{} = event, state), do: key(event, state)

  def handle_event(%Paste{content: text}, %{focus: :composer} = state),
    do: {:noreply, append_draft(state, text)}

  def handle_event(_event, state), do: {:noreply, state}

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
