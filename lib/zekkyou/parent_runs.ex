defmodule Zekkyou.ParentRuns do
  @moduledoc "Resident parent recovery selection and per-task shared budget policy."
  alias Alto.{OperationLog, Subagents.Continuation, Subagents.Journal}
  alias Alto.Runner.Budget.Account
  alias Zekkyou.{Config, Service}

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

  def options(opts, name, payload, approval_resume?) when is_list(opts) do
    with :ok <- matches_binding(opts, payload["parent_store"]) do
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
  catch
    :exit, reason -> %{state: "unavailable", reason: {:parent_store_unavailable, reason}}
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

  def decide_child(config, payload, requested) do
    with {:ok, opts} <- Config.resolve(config, payload["profile"]),
         :ok <- matches_binding(opts, payload["parent_store"]),
         store when not is_nil(store) <- Keyword.get(opts, :continuation_store),
         {:ok, candidate} when not is_nil(candidate) <-
           latest(store, payload["id"]),
         true <- candidate.phase == :pending,
         {:ok, cell} <-
           Continuation.restore(store, candidate.identity),
         {:ok, snapshot} <- Continuation.read(cell),
         binding = %{"key" => requested["key"], "generation" => requested["generation"]},
         true <- binding == snapshot.metadata["journal"],
         %{subagents: %{journal: journal}} when not is_nil(journal) <- Keyword.get(opts, :loop),
         {:ok, batch} <- Journal.restore(journal, binding),
         identity = %{
           "journal" => binding,
           "id" => requested["child"],
           "attempt" => requested["attempt"],
           "suspension" => requested["suspension"]
         },
         decision when decision in [:approve, :deny] <-
           %{"approve" => :approve, "deny" => :deny}[requested["decision"]],
         {:ok, _} <- Journal.decide(batch, requested["batch_revision"], identity, decision) do
      {:ok,
       %{
         "key" => candidate.identity["key"],
         "generation" => candidate.identity["generation"],
         "continuation_revision" => candidate.revision
       }}
    else
      false -> {:error, :stale_or_mismatched_child_continuation}
      {:ok, nil} -> {:error, :parent_continuation_not_found}
      {:error, _} = error -> error
      _ -> {:error, :invalid_child_decision}
    end
  end

  def store_binding(opts) do
    case Keyword.get(opts, :continuation_store) do
      nil -> {:ok, nil}
      store -> OperationLog.identity(store)
    end
  catch
    :exit, reason -> {:error, {:parent_store_unavailable, reason}}
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
      children = saved.packet["children"]

      if Enum.any?(children, &(&1["state"] == "decided")) do
        :ok
      else
        case Enum.find(children, &(&1["state"] != "completed")) do
          nil -> :ok
          child -> {:error, {:child_pending, child["id"], child["state"]}}
        end
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
    with {:ok, entries} <- Continuation.list(store, %{"host_key" => id}) do
      values =
        Enum.map(entries, fn %{identity: identity, snapshot: snapshot} ->
          %{
            identity: identity,
            revision: snapshot.revision,
            phase: snapshot.phase,
            operation_seq: snapshot.metadata["operation_seq"],
            session_id: snapshot.metadata["parent_session_id"]
          }
        end)

      {:ok, Enum.max_by(values, & &1.operation_seq, fn -> nil end)}
    end
  catch
    :exit, reason -> {:error, {:parent_store_unavailable, reason}}
  end
end
