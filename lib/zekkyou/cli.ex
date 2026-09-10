defmodule Zekkyou.CLI do
  @moduledoc "Command-line access to the resident service."

  alias Zekkyou.{Client, Config, Service}

  @help """
  Zekkyou — persistent agents built on Alto

  zekkyou serve CONFIG.exs
  zekkyou status [--socket PATH]
  zekkyou start PROFILE TASK [--socket PATH]
  zekkyou follow SESSION PROFILE TASK [--socket PATH]
  zekkyou watch RUN [--from-seq N] [--socket PATH]
  zekkyou history SESSION [--cursor N] [--socket PATH]
  zekkyou cancel RUN [--socket PATH]
  zekkyou approve REQUEST [--socket PATH]
  zekkyou deny REQUEST [--socket PATH]
  zekkyou schedule PROFILE TASK [--delay-ms N] [--id KEY] [--socket PATH]
  zekkyou tasks [--socket PATH]
  zekkyou task ID [--socket PATH]
  zekkyou task-cancel ID [--socket PATH]
  zekkyou task-reconcile ID committed|failed|retry --revision N --note TEXT [--socket PATH]

  Serve owns execution. Closing status/watch clients does not stop agents.
  Configuration is trusted Elixir code. Use SSH socket forwarding for remote access.
  """

  def main(args) do
    case run(args) do
      :ok ->
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "Zekkyou: #{inspect(reason)}")
        System.halt(1)
    end
  end

  def run(args) do
    {opts, args, invalid} =
      OptionParser.parse(
        args,
        strict: [
          socket: :string,
          from_seq: :integer,
          cursor: :integer,
          delay_ms: :integer,
          id: :string,
          revision: :integer,
          note: :string
        ]
      )

    if invalid == [] do
      dispatch(args, opts)
    else
      {:error, {:invalid_options, invalid}}
    end
  end

  defp dispatch([], _opts), do: IO.puts(@help)
  defp dispatch(["help"], _opts), do: IO.puts(@help)

  defp dispatch(["serve", path], _opts) do
    with {:ok, config} <- Config.load(path),
         {:ok, pid} <- Service.start(config) do
      IO.puts("Zekkyou is listening at #{Config.socket_path(config)}")
      monitor = Process.monitor(pid)

      receive do
        {:DOWN, ^monitor, :process, ^pid, reason} -> {:error, {:service_stopped, reason}}
      end
    end
  end

  defp dispatch(["watch", run], opts) do
    with {:ok, client} <- connect(opts) do
      try do
        with {:ok, _} <-
               Client.request(client, %{
                 "type" => "attach",
                 "run_id" => run,
                 "from_seq" => Keyword.get(opts, :from_seq, 1)
               }),
             do: watch(client)
      after
        Client.close(client)
      end
    end
  end

  defp dispatch(args, opts) do
    with {:ok, command} <- command(args, opts),
         {:ok, client} <- connect(opts) do
      try do
        case Client.request(client, command) do
          {:ok, reply} -> print(reply)
          {:error, reason} -> {:error, reason}
        end
      after
        Client.close(client)
      end
    end
  end

  defp command(["status"], _), do: {:ok, %{"type" => "sessions"}}

  defp command(["start", profile, task], _),
    do: {:ok, %{"type" => "start_run", "config" => profile, "task" => task}}

  defp command(["follow", session, profile, task], _),
    do: {:ok, %{"type" => "start_run", "config" => profile, "task" => task, "resume" => session}}

  defp command(["history", session], opts),
    do:
      {:ok,
       %{
         "type" => "session_events",
         "session_id" => session,
         "cursor" => Keyword.get(opts, :cursor, 0)
       }}

  defp command(["cancel", run], _),
    do: {:ok, %{"type" => "cancel", "run_id" => run, "reason" => "user"}}

  defp command(["schedule", profile, task], opts) do
    payload = %{"profile" => profile, "task" => task}
    payload = maybe_put(payload, "id", Keyword.get(opts, :id))
    payload = maybe_put(payload, "delay_ms", Keyword.get(opts, :delay_ms))
    {:ok, command_wire("tasks.submit", payload)}
  end

  defp command(["tasks"], _opts), do: {:ok, command_wire("tasks.list", %{})}

  defp command(["task", id], _opts), do: {:ok, command_wire("tasks.get", %{"id" => id})}

  defp command(["task-cancel", id], _opts),
    do: {:ok, command_wire("tasks.cancel", %{"id" => id})}

  defp command(["task-reconcile", id, resolution], opts)
       when resolution in ["committed", "failed", "retry"] do
    revision = Keyword.get(opts, :revision)
    note = Keyword.get(opts, :note)

    cond do
      not (is_integer(revision) and revision > 0) ->
        {:error, {:invalid_task_reconcile, :revision}}

      not (is_binary(note) and String.trim(note) != "") ->
        {:error, {:invalid_task_reconcile, :note}}

      true ->
        {:ok,
         command_wire("tasks.reconcile", %{
           "id" => id,
           "resolution" => resolution,
           "revision" => revision,
           "note" => note
         })}
    end
  end

  defp command([decision, request], _) when decision in ["approve", "deny"],
    do:
      {:ok,
       %{
         "type" => "approval_response",
         "request_id" => request,
         "decision" => if(decision == "approve", do: "approve", else: %{"deny" => "user"})
       }}

  defp command(_, _), do: {:error, :invalid_command}

  defp command_wire(name, payload),
    do: %{"type" => "command", "name" => name, "payload" => payload}

  defp maybe_put(payload, _key, nil), do: payload
  defp maybe_put(payload, key, value), do: Map.put(payload, key, value)

  defp connect(opts) do
    path = Keyword.get(opts, :socket, Path.join(Config.default_state_dir(), "service.sock"))
    Client.connect(path)
  end

  defp watch(client) do
    case Client.next(client, 30_000) do
      {:ok, %{"type" => "result"} = event} ->
        print(event)

      {:ok, event} ->
        print(event)
        watch(client)

      {:error, :timeout} ->
        watch(client)

      {:error, reason} ->
        {:error, {:disconnected, reason}}
    end
  end

  defp print(value), do: value |> JSON.encode!() |> IO.puts()
end
