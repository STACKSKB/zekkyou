defmodule Zekkyou.ChildRuns do
  @moduledoc "Resident child journals and read-only operator recovery, backed by Alto."

  alias Alto.OperationLog
  alias Alto.Subagents.Journal
  alias Zekkyou.Service

  def child(config, name) do
    Supervisor.child_spec(
      {OperationLog,
       name: ledger(name),
       id: "team-children",
       dir: Path.join(config.state_dir, "operations"),
       max_ops: config.child_runs[:max_retained],
       max_log_bytes: config.child_runs[:max_log_bytes],
       max_recovery_bytes: config.child_runs[:max_batch_bytes],
       max_record_bytes: config.child_runs[:max_batch_bytes] * 2 + 10_000},
      id: __MODULE__
    )
  end

  @doc "Stable resident journal name for Team.loop/1's trusted :journal option."
  def ledger(name \\ Service), do: Service.component(name, :child_runs)

  def commands(name) do
    Map.new(~w(list get result), fn action ->
      {"children." <> action, fn args -> execute(ledger(name), action, args) end}
    end)
  end

  defp execute(ledger, "list", args) when is_map(args) do
    cursor = Map.get(args, "cursor", 0)

    if is_integer(cursor) and cursor >= 0 do
      keys = ledger |> OperationLog.keys() |> Enum.sort()
      page = Enum.slice(keys, cursor, 10)

      batches =
        Enum.map(page, fn key ->
          case read(ledger, key) do
            {:ok, snapshot} -> summary(key, snapshot)
            {:error, reason} -> %{key: key, state: "unavailable", reason: reason}
          end
        end)

      next = cursor + length(page)
      {:ok, %{batches: batches, next_cursor: if(next < length(keys), do: next)}}
    else
      {:error, :invalid_child_cursor}
    end
  end

  defp execute(ledger, "get", %{"key" => key}) when is_binary(key) do
    with {:ok, snapshot} <- read(ledger, key) do
      children = Enum.map(snapshot.packet["children"], &Map.drop(&1, ["result"]))

      {:ok,
       summary(key, snapshot)
       |> Map.put(:metadata, snapshot.packet["metadata"])
       |> Map.put(:children, children)}
    end
  end

  defp execute(
         ledger,
         "result",
         %{"key" => key, "child" => id, "generation" => generation, "revision" => revision} = args
       )
       when is_binary(key) and is_binary(id) and is_binary(generation) and
              is_integer(revision) and revision > 0 do
    with {:ok, snapshot} <- read(ledger, key),
         :ok <- viewed(snapshot, generation, revision),
         {:ok, encoded} <- retained_result(snapshot.packet["children"], id),
         {:ok, chunk} <- chunk(encoded, Map.get(args, "cursor", 0)) do
      {:ok,
       Map.merge(chunk, %{
         key: key,
         child: id,
         generation: generation,
         revision: revision,
         encoding: "alto_portable_term_base64",
         bytes: byte_size(encoded),
         sha256: :crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower)
       })}
    end
  end

  defp execute(_, _, _), do: {:error, :invalid_child_command}

  defp read(ledger, key) do
    with {:ok, entry} <- OperationLog.recovery(ledger, key),
         %{tool: "alto_subagent_batch", recovery: %{"generation" => generation}} <- entry,
         {:ok, batch} <- Journal.restore(ledger, %{"key" => key, "generation" => generation}),
         {:ok, snapshot} <- Journal.read(batch) do
      {:ok, snapshot}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_child_batch}
    end
  end

  defp summary(key, snapshot) do
    packet = snapshot.packet

    # List pages need only bounded parent identifiers; detail inspection retains
    # full metadata. Never place every child's result in one transport response.
    metadata =
      packet["metadata"]
      |> Map.take(["parent_run_id", "parent_session_id"])
      |> Map.filter(fn {_key, value} -> is_binary(value) and byte_size(value) <= 256 end)

    %{
      key: key,
      generation: packet["generation"],
      revision: snapshot.revision,
      state: to_string(snapshot.state),
      metadata: metadata,
      counts: Enum.frequencies_by(packet["children"], & &1["state"]),
      joined: is_map(packet["join"])
    }
  end

  defp viewed(%{revision: revision, packet: %{"generation" => generation}}, generation, revision),
    do: :ok

  defp viewed(_, _, _), do: {:error, :stale_child_batch}

  defp retained_result(children, id) do
    case Enum.find(children, &(&1["id"] == id)) do
      %{"state" => "completed", "result" => result} -> {:ok, result}
      %{"state" => state} -> {:error, {:child_result_pending, state}}
      nil -> {:error, :unknown_child}
    end
  end

  # Export the exact retained encoding without loading terms or guessing which
  # custom result atoms exist in this VM. Export never acknowledges consumption.
  defp chunk(encoded, cursor)
       when is_integer(cursor) and cursor >= 0 and cursor <= byte_size(encoded) do
    count = min(24_000, byte_size(encoded) - cursor)
    next = cursor + count

    {:ok,
     %{
       chunk: binary_part(encoded, cursor, count),
       next_cursor: if(next < byte_size(encoded), do: next)
     }}
  end

  defp chunk(_, _), do: {:error, :invalid_child_cursor}
end
