defmodule Zekkyou.Effort do
  @moduledoc "Discover public effort capabilities for a service-owned model."

  def catalog(config, profile) do
    with {:ok, options} <- Zekkyou.Config.resolve(config, profile),
         {:ok, module, opts} <- provider(options),
         {:ok, models} <- models(options, module, opts) do
      id = opts[:model]
      model = Enum.find(models, &((&1[:id] || &1["id"]) == id))
      {:ok, %{model: id, efforts: Alto.Reasoning.efforts(model)}}
    else
      {:error, :provider_required} -> {:ok, %{model: nil, efforts: []}}
      error -> error
    end
  end

  def model(options) do
    case provider(options) do
      {:ok, _module, opts} -> opts[:model]
      _ -> nil
    end
  end

  defp provider(options) do
    case options[:provider] do
      {module, opts} when is_atom(module) and is_list(opts) -> {:ok, module, opts}
      module when is_atom(module) and not is_nil(module) -> {:ok, module, []}
      _ -> {:error, :provider_required}
    end
  end

  defp models(options, module, opts) do
    {:ok, profiles} = Alto.Harness.ProviderProfile.from_run_options(options)

    configured =
      Enum.find(
        profiles,
        &(&1.module == module and &1.default_model == opts[:model] and is_list(&1.models))
      )

    cond do
      is_list(opts[:reasoning_efforts]) ->
        {:ok, [%{id: opts[:model], efforts: opts[:reasoning_efforts]}]}

      configured ->
        {:ok, configured.models}

      Code.ensure_loaded?(module) and function_exported?(module, :list_models, 1) ->
        module.list_models(Keyword.put(opts, :timeout, 5000))

      true ->
        {:ok, []}
    end
  end
end
