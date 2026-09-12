defmodule Zekkyou.Lifecycle do
  @moduledoc "Explicit terminal-task cleanup with a durable, restartable retirement plan."
  alias Alto.OperationLog
  alias Alto.Runner.Budget.Account
  alias Alto.Subagents.{Continuation, Journal}
  alias Zekkyou.{Config, ParentRuns, Service}

  @tool "zekkyou_task_cleanup"
  @attempt "retire-resources"

  def ledger(name \\ Service), do: Service.component(name, :cleanup)

  def child(config, name) do
    Supervisor.child_spec(
      {OperationLog,
       name: ledger(name),
       id: "task-cleanup",
       dir: Path.join(config.state_dir, "operations"),
       max_ops: config.scheduling[:max_tasks],
       max_recovery_bytes: 1_000_000,
       max_record_bytes: 2_000_000},
      id: __MODULE__
    )
  end

  # Tasks serializes admission/reconciliation and establishes terminality first.
  # The complete plan is durable before any component becomes evictable.
  def cleanup(config, name, recovered) do
    payload = recovered.recovery[:payload]
    generation = recovered.recovery[:generation_id]
    key = payload["id"] <> ":" <> generation

    with {:ok, opts} <- Config.resolve(config, payload["profile"]),
         {:ok, binding} <- ParentRuns.store_binding(opts),
         true <- not is_nil(binding) and binding == payload["parent_store"],
         {:ok, stores} <- stores(opts, name),
         {:ok, entry} <-
           plan(ledger(name), key, payload, generation, recovered.revision, stores, opts),
         :ok <- execute(ledger(name), key, entry, stores) do
      cleaned(payload["id"], entry)
    else
      false -> {:error, :parent_recovery_configuration_mismatch}
      {:error, _} = error -> error
    end
  catch
    :exit, reason -> {:error, {:cleanup_store_unavailable, reason}}
  end

  @doc "Finish a previously planned cleanup after its terminal task record was evicted."
  def resume(config, name, id, task_revision)
      when is_binary(id) and is_integer(task_revision) and task_revision > 0 do
    with {:ok, key, entry} <- find_plan(ledger(name), id, task_revision),
         {:ok, opts} <- Config.resolve(config, entry.recovery["profile"]),
         {:ok, binding} <- ParentRuns.store_binding(opts),
         true <- binding == entry.recovery["parent_store"],
         {:ok, stores} <- stores(opts, name),
         true <- store_bindings(stores) == entry.recovery["stores"],
         :ok <- execute(ledger(name), key, entry, stores) do
      cleaned(id, entry)
    else
      false -> {:error, :cleanup_plan_mismatch}
      {:error, _} = error -> error
    end
  catch
    :exit, reason -> {:error, {:cleanup_store_unavailable, reason}}
  end

  def resume(_, _, _, _), do: {:error, :invalid_cleanup_request}

  @doc "Deny task id reuse while its cleanup, owned budget, or selected parent store retains state."
  def available?(config, name, %{"id" => id, "profile" => profile}) do
    with {:ok, opts} <- Config.resolve(config, profile),
         :ok <- unreserved_budget(ParentRuns.budgets(name), id),
         :ok <- unreserved_cleanup(ledger(name), id),
         :ok <- unreserved_parent(Keyword.get(opts, :continuation_store), id) do
      :ok
    end
  catch
    :exit, reason -> {:error, {:cleanup_store_unavailable, reason}}
  end

  def available?(_, _, _), do: {:error, :invalid_cleanup_request}

  defp cleaned(id, entry) do
    {:ok, %{task_id: id, status: "cleaned", resources: length(entry.recovery["resources"])}}
  end

  defp find_plan(ledger, id, task_revision) do
    matches =
      ledger
      |> OperationLog.keys()
      |> Enum.filter(&String.starts_with?(&1, id <> ":"))
      |> collect(fn key ->
        with {:ok, entry} <- OperationLog.recovery(ledger, key) do
          recovery = entry.recovery

          if entry.tool == @tool and is_map(recovery) and recovery["task"] == id and
               recovery["task_revision"] == task_revision,
             do: {:ok, {key, entry}},
             else: {:ok, nil}
        end
      end)

    case matches do
      {:ok, [{key, entry}]} -> {:ok, key, entry}
      {:ok, []} -> {:error, :cleanup_plan_not_found}
      {:ok, _} -> {:error, :ambiguous_cleanup_plan}
      error -> error
    end
  end

  defp unreserved_cleanup(ledger, id) do
    if Enum.any?(OperationLog.keys(ledger), &String.starts_with?(&1, id <> ":")),
      do: {:error, :task_id_retained},
      else: :ok
  end

  defp unreserved_budget(server, id) do
    case OperationLog.recovery(server, "task:" <> id) do
      {:error, :not_found} -> :ok
      {:ok, _} -> {:error, :task_id_retained}
      error -> error
    end
  end

  defp unreserved_parent(nil, _id), do: :ok

  defp unreserved_parent(server, id) do
    server
    |> OperationLog.keys()
    |> collect(fn key ->
      with {:ok, entry} <- OperationLog.recovery(server, key) do
        if get_in(entry.checkpoint || %{}, ["metadata", "host_key"]) == id,
          do: {:error, :task_id_retained},
          else: {:ok, nil}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp stores(opts, name) do
    servers = %{
      "parent" => Keyword.fetch!(opts, :continuation_store),
      "budget" => ParentRuns.budgets(name)
    }

    servers =
      case Keyword.get(opts, :loop) do
        %{subagents: %{journal: journal}} when not is_nil(journal) ->
          Map.put(servers, "journal", journal)

        _ ->
          servers
      end

    Enum.reduce_while(servers, {:ok, %{}}, fn {role, server}, {:ok, acc} ->
      case OperationLog.identity(server) do
        {:ok, identity} ->
          {:cont, {:ok, Map.put(acc, role, %{server: server, identity: identity})}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp plan(ledger, key, payload, generation, task_revision, stores, opts) do
    task = payload["id"]
    bindings = store_bindings(stores)

    case OperationLog.recovery(ledger, key) do
      {:ok,
       %{
         tool: @tool,
         recovery: %{
           "task" => ^task,
           "generation" => ^generation,
           "task_revision" => ^task_revision,
           "profile" => profile,
           "parent_store" => parent_store,
           "stores" => ^bindings
         }
       } = entry} ->
        if profile == payload["profile"] and parent_store == payload["parent_store"],
          do: {:ok, entry},
          else: {:error, :cleanup_plan_mismatch}

      {:ok, _} ->
        {:error, :cleanup_plan_mismatch}

      {:error, :not_found} ->
        with {:ok, resources} <- resources(task, stores, opts),
             :ok <-
               OperationLog.record_intent(ledger, key, @tool, nil, %{
                 "task" => task,
                 "generation" => generation,
                 "task_revision" => task_revision,
                 "profile" => payload["profile"],
                 "parent_store" => payload["parent_store"],
                 "stores" => bindings,
                 "resources" => resources
               }) do
          OperationLog.recovery(ledger, key)
        end

      error ->
        error
    end
  end

  defp store_bindings(stores),
    do: Map.new(stores, fn {role, store} -> {role, store.identity} end)

  defp resources(task, stores, opts) do
    parent = stores["parent"].server

    with {:ok, cells} <-
           collect(OperationLog.keys(parent), fn key ->
             with {:ok, entry} <- OperationLog.recovery(parent, key) do
               if get_in(entry.checkpoint || %{}, ["metadata", "host_key"]) == task do
                 with :ok <- require_journal(stores),
                      {:ok, cell} <- Continuation.restore(parent, identity(key, entry)),
                      {:ok, snapshot} <- Continuation.read(cell),
                      true <- snapshot.phase == :claimed,
                      {:ok, batch} <-
                        Journal.restore(stores["journal"].server, snapshot.metadata["journal"]),
                      {:ok, journal} <- Journal.read(batch),
                      %{"continuation" => binding} <- journal.packet["join"],
                      true <- binding == Continuation.identity(cell) do
                   {:ok,
                    %{
                      cell: resource("parent", Continuation.identity(cell), snapshot),
                      journal: resource("journal", Journal.identity(batch), journal),
                      account: snapshot.packet["budget"]["account"]
                    }}
                 else
                   false -> {:error, :unconsumed_parent_resources}
                   nil -> {:error, :unconsumed_parent_resources}
                   {:error, _} = error -> error
                   _ -> {:error, :parent_join_receipt_mismatch}
                 end
               else
                 {:ok, nil}
               end
             end
           end),
         {:ok, accounts} <- owned_account(task, cells, stores, opts) do
      {:ok, Enum.map(cells, & &1.journal) ++ Enum.map(cells, & &1.cell) ++ accounts}
    else
      {:error, _} = error -> error
    end
  end

  defp require_journal(%{"journal" => _}), do: :ok
  defp require_journal(_), do: {:error, :child_journal_required}

  defp owned_account(task, cells, stores, opts) do
    # An explicitly supplied profile account may span tasks and belongs to its host.
    if Keyword.has_key?(opts, :budget_account) do
      {:ok, []}
    else
      key = "task:" <> task

      case Enum.uniq(Enum.map(cells, & &1.account)) do
        [] ->
          case OperationLog.recovery(stores["budget"].server, key) do
            {:ok, %{recovery: %{"generation" => generation}}} ->
              account = %Account{
                ledger: stores["budget"].server,
                key: key,
                generation: generation
              }

              with {:ok, snapshot} <- Account.read(account),
                   do: {:ok, [resource("budget", Account.identity(account), snapshot)]}

            {:error, :not_found} ->
              {:ok, []}

            error ->
              error
          end

        [%{"key" => ^key, "generation" => generation} = binding] ->
          account = %Account{ledger: stores["budget"].server, key: key, generation: generation}

          with {:ok, snapshot} <- Account.read(account),
               do: {:ok, [resource("budget", binding, snapshot)]}

        _ ->
          {:error, :task_budget_ownership_mismatch}
      end
    end
  end

  defp execute(_, _, %{status: {:decided, :completed, _}}, _), do: :ok

  defp execute(ledger, key, entry, stores) do
    with :ok <- OperationLog.record_attempt(ledger, key, @attempt),
         {:ok, _} <- collect(entry.recovery["resources"], &retire(&1, stores)),
         :ok <-
           OperationLog.record_outcome(ledger, key, @attempt, :completed, %{
             resources: length(entry.recovery["resources"])
           }) do
      :ok
    end
  end

  defp retire(resource, stores) do
    server = stores[resource["role"]].server
    binding = resource["identity"]
    # Only terminal records can be evicted or replaced. The saved cleanup intent
    # authorizes finishing that original generation, never touching its successor.
    case OperationLog.recovery(server, binding["key"]) do
      {:error, :not_found} ->
        {:ok, :retired}

      {:ok, entry} ->
        if entry.recovery["generation"] != binding["generation"] do
          {:ok, :retired}
        else
          retire_existing(resource, server)
        end

      error ->
        error
    end
  end

  defp retire_existing(%{"role" => role, "identity" => binding, "revision" => revision}, server) do
    {handle, module, method} =
      case role do
        "budget" ->
          {%Account{ledger: server, key: binding["key"], generation: binding["generation"]},
           Account, :close}

        "parent" ->
          {%Continuation{ledger: server, key: binding["key"], generation: binding["generation"]},
           Continuation, :retire}

        "journal" ->
          {%Journal{ledger: server, key: binding["key"], generation: binding["generation"]},
           Journal, :retire}
      end

    with {:ok, snapshot} <- module.read(handle),
         true <- snapshot.state != :active or snapshot.revision == revision,
         :ok <- apply(module, method, [handle, snapshot.revision]) do
      {:ok, :retired}
    else
      false -> {:error, :stale_cleanup_resource}
      {:error, _} = error -> error
    end
  end

  defp resource(role, binding, snapshot),
    do: %{"role" => role, "identity" => binding, "revision" => snapshot.revision}

  defp identity(key, entry), do: %{"key" => key, "generation" => entry.recovery["generation"]}

  defp collect(values, fun) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case fun.(value) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end
end
