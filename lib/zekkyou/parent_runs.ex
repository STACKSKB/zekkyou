defmodule Zekkyou.ParentRuns do
  @moduledoc "Resident parent recovery selection and per-task shared budget policy."
  alias Alto.{OperationLog, Subagents.Continuation, Subagents.Journal}
  alias Alto.Runner.Budget.Account
  alias Zekkyou.{Config, Service, Tasks}

  def ledger(name \\ Service), do: Service.component(name, :parent_runs)
  def budgets(name \\ Service), do: Service.component(name, :task_budgets)

  def children(config, name) do
    Enum.map(
      [{ledger(name), "parent-continuations"}, {budgets(name), "task-budgets"}],
      fn {server, id} ->
        Supervisor.child_spec(
          {OperationLog,
           name: server,
           id: id,
           dir: Path.join(config.state_dir, "operations"),
           max_ops: config.scheduling[:max_tasks],
           max_log_bytes: config.child_runs[:max_log_bytes],
           max_recovery_bytes: 3_000_000,
           max_record_bytes: 6_000_000},
          id: {__MODULE__, id}
        )
      end
    )
  end

  def options(config, name, payload, approval_resume?) do
    with {:ok, opts} <- Tasks.resolve(config, "scheduled/" <> payload["profile"]),
         :ok <- matches_binding(opts, payload["parent_store"]) do
      case Keyword.get(opts, :continuation_store) do
        nil ->
          {:ok, []}

        store ->
          with {:ok, account} <- account(opts, name, payload["id"]),
               {:ok, candidate} <- latest(store, payload["id"]) do
            extra = [budget_account: account, continuation_key: payload["id"]]

            if approval_resume? or is_nil(candidate),
              do: {:ok, extra},
              else: {:ok, Keyword.put(extra, :continuation, candidate.identity)}
          end
      end
    end
  end

  def inspect_task(config, profile, id, binding \\ nil) do
    with {:ok, opts} <- Config.resolve(config, profile),
         :ok <- matches_binding(opts, binding),
         store when not is_nil(store) <- Keyword.get(opts, :continuation_store),
         {:ok, candidate} <- latest(store, id) do
      candidate
    else
      nil -> nil
      {:error, reason} -> %{state: "unavailable", reason: reason}
    end
  end

  def recoverable(config, profile, id, requested, binding) do
    with {:ok, opts} <- Config.resolve(config, profile),
         :ok <- matches_binding(opts, binding),
         store when not is_nil(store) <- Keyword.get(opts, :continuation_store),
         {:ok, candidate} when not is_nil(candidate) <- latest(store, id),
         true <-
           requested["key"] == candidate.identity["key"] and
             requested["generation"] == candidate.identity["generation"] and
             requested["continuation_revision"] == candidate.revision,
         true <- candidate.phase in [:pending, :ready],
         {:ok, cell} <- Continuation.restore(store, candidate.identity),
         {:ok, snapshot} <- Continuation.read(cell),
         :ok <- completed_children(opts, snapshot) do
      :ok
    else
      false -> {:error, :stale_or_claimed_parent_continuation}
      nil -> {:error, :parent_recovery_not_enabled}
      {:ok, nil} -> {:error, :parent_continuation_not_found}
      {:error, _} = error -> error
    end
  end

  def store_binding(opts) do
    case Keyword.get(opts, :continuation_store) do
      nil -> {:ok, nil}
      store -> OperationLog.identity(store)
    end
  end

  defp matches_binding(opts, expected) do
    with {:ok, actual} <- store_binding(opts) do
      if actual == expected, do: :ok, else: {:error, :parent_recovery_configuration_mismatch}
    end
  end

  defp completed_children(_opts, %{phase: :ready}), do: :ok

  defp completed_children(opts, snapshot) do
    spec = Keyword.fetch!(opts, :loop)
    journal = spec.subagents.journal

    with {:ok, batch} <- Journal.restore(journal, snapshot.metadata["journal"]),
         {:ok, saved} <- Journal.read(batch) do
      # Admission inspection precedes loading the runner's result vocabulary.
      # The runner validates/decodes the exact join before granting effects.
      case Enum.find(saved.packet["children"], &(&1["state"] != "completed")) do
        nil -> :ok
        child -> {:error, {:child_pending, child["id"], child["state"]}}
      end
    end
  end

  defp account(opts, name, id) do
    case Keyword.get(opts, :budget_account) do
      nil ->
        Account.open(budgets(name), "task:" <> id,
          max_effects: Keyword.fetch!(opts, :max_effects),
          max_model_requests: Keyword.fetch!(opts, :max_model_requests)
        )

      %Account{} = account ->
        {:ok, account}

      _ ->
        {:error, :invalid_task_budget_account}
    end
  end

  defp latest(store, id) do
    OperationLog.keys(store)
    |> Enum.reduce_while({:ok, []}, fn key, {:ok, acc} ->
      with {:ok, entry} <- OperationLog.recovery(store, key) do
        if get_in(entry.checkpoint || %{}, ["metadata", "host_key"]) == id do
          identity = %{"key" => key, "generation" => entry.recovery["generation"]}

          with {:ok, cell} <- Continuation.restore(store, identity),
               {:ok, snapshot} <- Continuation.read(cell) do
            value = %{
              identity: identity,
              revision: snapshot.revision,
              phase: snapshot.phase,
              operation_seq: snapshot.metadata["operation_seq"],
              session_id: snapshot.metadata["parent_session_id"]
            }

            {:cont, {:ok, [value | acc]}}
          else
            error -> {:halt, error}
          end
        else
          {:cont, {:ok, acc}}
        end
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, []} -> {:ok, nil}
      {:ok, values} -> {:ok, Enum.max_by(values, & &1.operation_seq)}
      error -> error
    end
  end
end
