defmodule Zekkyou.Workspaces do
  @moduledoc "Resident workspace resources and operator review, backed by Alto."
  alias Alto.{OperationLog, Workspaces}
  alias Zekkyou.Service

  def child(config, name) do
    Supervisor.child_spec(
      {OperationLog,
       name: ledger(name),
       id: "workspaces",
       dir: Path.join(config.state_dir, "operations"),
       max_ops: config.workspaces[:max_retained],
       max_log_bytes: config.workspaces[:max_log_bytes],
       max_recovery_bytes: 40_000,
       max_record_bytes: 100_000},
      id: __MODULE__
    )
  end

  def ledger(name \\ Service), do: Service.component(name, :workspaces)

  @doc "Pass this manager to Team.loop/1 as :workspaces in trusted profile configuration."
  def manager(state_dir, name \\ Service) do
    Workspaces.new(root: Path.join(state_dir, "workspaces"), ledger: ledger(name))
  end

  def commands(config, name) do
    manager = manager(config.state_dir, name)

    Map.new(~w(list get patch discard), fn action ->
      {"workspaces." <> action, fn args -> execute(manager, action, args) end}
    end)
  end

  defp execute(manager, "list", args) when is_map(args) do
    cursor = Map.get(args, "cursor", 0)

    if is_integer(cursor) and cursor >= 0 do
      keys = OperationLog.keys(manager.ledger)
      page = Enum.slice(keys, cursor, 10)

      resources =
        Enum.flat_map(page, fn id ->
          case Workspaces.get(manager, id) do
            {:ok, info} -> [info]
            _ -> []
          end
        end)

      next = cursor + length(page)
      {:ok, %{workspaces: resources, next_cursor: if(next < length(keys), do: next)}}
    else
      {:error, :invalid_workspace_cursor}
    end
  end

  defp execute(manager, "get", %{"id" => id}) do
    with {:ok, info} <- Workspaces.get(manager, id), do: {:ok, public_info(info)}
  end

  defp execute(manager, "patch", %{"id" => id} = args) do
    cursor = Map.get(args, "cursor", 0)

    with true <- is_integer(cursor) and cursor >= 0,
         {:ok, info} <- Workspaces.get(manager, id),
         {:ok, patch} <- Workspaces.patch(manager, id),
         true <- cursor <= byte_size(patch) do
      count = min(24_000, byte_size(patch) - cursor)
      next = cursor + count

      {:ok,
       %{
         workspace_id: id,
         revision: info.revision,
         sha256: info.workspace["patch_sha256"],
         bytes: byte_size(patch),
         encoding: "base64",
         chunk: patch |> binary_part(cursor, count) |> Base.encode64(),
         next_cursor: if(next < byte_size(patch), do: next)
       }}
    else
      false -> {:error, :invalid_workspace_cursor}
      {:error, _} = error -> error
    end
  end

  defp execute(manager, "discard", %{"id" => id, "revision" => revision, "note" => note}) do
    with {:ok, info} <- Workspaces.discard(manager, id, revision, note),
         do: {:ok, public_info(info)}
  end

  defp execute(_manager, _action, _args), do: {:error, :invalid_workspace_command}

  defp public_info(info), do: info |> Map.delete(:id) |> Map.put(:workspace_id, info.id)
end
