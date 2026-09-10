defmodule Zekkyou.Config do
  @moduledoc "Trusted service configuration; clients may select only registered profiles."

  @enforce_keys [:workspace, :state_dir, :profiles]
  defstruct [
    :workspace,
    :state_dir,
    :profiles,
    max_retained_events: 1_000,
    runtime: Zekkyou.Runtime.Alto
  ]

  @type t :: %__MODULE__{
          workspace: Path.t(),
          state_dir: Path.t(),
          profiles: map(),
          max_retained_events: pos_integer(),
          runtime: module()
        }

  def new(opts) when is_list(opts) do
    unless Keyword.keyword?(opts),
      do: raise(ArgumentError, "service options must be a keyword list")

    unknown =
      Keyword.keys(opts) -- [:workspace, :state_dir, :profiles, :max_retained_events, :runtime]

    if unknown != [], do: raise(ArgumentError, "unknown service options: #{inspect(unknown)}")
    workspace = opts |> Keyword.fetch!(:workspace) |> Path.expand()
    state_dir = opts |> Keyword.get(:state_dir, default_state_dir()) |> Path.expand()
    profiles = Keyword.fetch!(opts, :profiles)
    retention = Keyword.get(opts, :max_retained_events, 1_000)
    runtime = Keyword.get(opts, :runtime, Zekkyou.Runtime.Alto)

    unless is_atom(runtime) and Code.ensure_loaded?(runtime) and
             function_exported?(runtime, :children, 2),
           do: raise(ArgumentError, "runtime must implement Zekkyou.Runtime")

    unless File.dir?(workspace), do: raise(ArgumentError, "workspace must be a directory")

    unless is_map(profiles) and map_size(profiles) > 0 and
             Enum.all?(profiles, fn {name, config} ->
               is_binary(name) and byte_size(name) in 1..100 and match?(%Alto.Config{}, config)
             end),
           do: raise(ArgumentError, "profiles must map names to Alto.Config values")

    unless is_integer(retention) and retention in 1..100_000,
      do: raise(ArgumentError, "max_retained_events must be between 1 and 100000")

    %__MODULE__{
      workspace: workspace,
      state_dir: state_dir,
      profiles: profiles,
      max_retained_events: retention,
      runtime: runtime
    }
  end

  def load(path) do
    case Code.eval_file(Path.expand(path)) do
      {%__MODULE__{} = config, _} -> {:ok, new(Map.to_list(Map.from_struct(config)))}
      _ -> {:error, :expected_zekkyou_config}
    end
  rescue
    error -> {:error, {:config_load_failed, Exception.message(error)}}
  end

  def default_state_dir do
    base = System.get_env("XDG_STATE_HOME") || Path.join(System.user_home!(), ".local/state")
    Path.join(base, "zekkyou")
  end

  def socket_path(%__MODULE__{state_dir: dir}), do: Path.join(dir, "service.sock")

  def resolve(%__MODULE__{profiles: profiles}, name) do
    case Map.fetch(profiles, name) do
      {:ok, config} -> {:ok, Alto.Config.run_options(config)}
      :error -> {:error, {:unknown_profile, name}}
    end
  end
end
