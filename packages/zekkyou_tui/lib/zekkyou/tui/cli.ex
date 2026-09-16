defmodule Zekkyou.TUI.CLI do
  @moduledoc "Command line entry point for zekkyou-tui."

  @help """
  Usage: zekkyou-tui [--socket PATH] [--profile PROFILE]
         zekkyou-tui --ssh HOST --remote-socket PATH [--port N] [--profile PROFILE]

  Tab focuses tasks or composer; arrows select tasks; Enter sends a message.
  Ctrl+Q detaches, Ctrl+R reconnects, Ctrl+N starts a new task, Ctrl+K cancels.
  Ctrl+A approves the displayed request, Ctrl+D denies. Page Up/Down scroll.
  Drag anywhere to select; Ctrl+C or Alt+C copies; Esc clears selection.
  Ctrl+Shift+A selects the visible screen. Use terminal paste or Ctrl+V to paste.
  """

  def main(argv) do
    case run(argv) do
      :ok ->
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "Zekkyou TUI: #{inspect(reason)}")
        System.halt(1)
    end
  end

  def run(argv) do
    case options(argv) do
      :help ->
        IO.puts(@help)

      {:error, _} = error ->
        error

      {:ok, opts} ->
        with {:ok, _} <- Application.ensure_all_started(:zekkyou_tui), do: start(opts)
    end
  end

  @doc false
  def options(argv) do
    {opts, rest, invalid} =
      OptionParser.parse(argv,
        strict: [
          socket: :string,
          profile: :string,
          ssh: :string,
          remote_socket: :string,
          port: :integer,
          help: :boolean
        ],
        aliases: [h: :help]
      )

    cond do
      rest != [] or invalid != [] ->
        {:error, {:invalid_options, invalid ++ rest}}

      opts[:help] == true ->
        :help

      opts[:ssh] != nil and opts[:remote_socket] == nil ->
        {:error, :remote_socket_required}

      opts[:ssh] != nil and opts[:socket] != nil ->
        {:error, :choose_socket_or_ssh}

      opts[:ssh] == nil and (opts[:remote_socket] != nil or opts[:port] != nil) ->
        {:error, :ssh_host_required}

      opts[:port] != nil and opts[:port] not in 1..65_535 ->
        {:error, :invalid_port}

      true ->
        {:ok, opts}
    end
  end

  defp start(opts) do
    case Zekkyou.TUI.App.start_link(
           opts
           |> Keyword.put(:name, nil)
           |> Keyword.put(:mouse_capture, true)
         ) do
      {:ok, pid} ->
        Process.unlink(pid)
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, :normal} -> :ok
          {:DOWN, ^ref, :process, ^pid, reason} -> {:error, {:tui_stopped, reason}}
        end

      {:error, reason} ->
        {:error, {:tui_start_failed, reason}}
    end
  end
end
