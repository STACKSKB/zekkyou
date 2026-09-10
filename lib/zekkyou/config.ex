defmodule Zekkyou.Config do
  @moduledoc "Trusted service configuration; clients may select only registered profiles."

  @enforce_keys [:workspace, :state_dir, :profiles]
  defstruct [
    :workspace,
    :state_dir,
    :profiles,
    max_retained_events: 1_000,
    runtime: Zekkyou.Runtime.Alto,
    workspaces: [max_retained: 128, max_log_bytes: 64_000_000],
    mailbox: [
      auto_compact: true,
      max_messages: 1_000,
      max_completed: 10_000,
      lease_ms: 30_000,
      max_log_bytes: 64_000_000
    ],
    scheduling: [
      workers: 2,
      max_attempts: 3,
      poll_ms: 250,
      run_timeout: 300_000,
      max_model_requests: 64,
      max_effects: 1_000,
      max_pending: 100,
      max_tasks: 1_000
    ]
  ]

  @type t :: %__MODULE__{
          workspace: Path.t(),
          state_dir: Path.t(),
          profiles: map(),
          max_retained_events: pos_integer(),
          runtime: module(),
          workspaces: keyword(),
          mailbox: keyword(),
          scheduling: keyword()
        }

  def new(opts) when is_list(opts) do
    unless Keyword.keyword?(opts),
      do: raise(ArgumentError, "service options must be a keyword list")

    unknown =
      Keyword.keys(opts) --
        [
          :workspace,
          :state_dir,
          :profiles,
          :max_retained_events,
          :runtime,
          :scheduling,
          :mailbox,
          :workspaces
        ]

    if unknown != [], do: raise(ArgumentError, "unknown service options: #{inspect(unknown)}")
    workspace = opts |> Keyword.fetch!(:workspace) |> Path.expand()
    state_dir = opts |> Keyword.get(:state_dir, default_state_dir()) |> Path.expand()
    profiles = Keyword.fetch!(opts, :profiles)
    retention = Keyword.get(opts, :max_retained_events, 1_000)
    runtime = Keyword.get(opts, :runtime, Zekkyou.Runtime.Alto)
    scheduling = scheduling_options(Keyword.get(opts, :scheduling, []))
    mailbox = mailbox_options(Keyword.get(opts, :mailbox, []))
    workspaces = workspace_options(Keyword.get(opts, :workspaces, []))

    unless is_atom(runtime) and Code.ensure_loaded?(runtime) and
             function_exported?(runtime, :children, 2),
           do: raise(ArgumentError, "runtime must implement Zekkyou.Runtime")

    unless File.dir?(workspace), do: raise(ArgumentError, "workspace must be a directory")

    unless is_map(profiles) and map_size(profiles) > 0 and
             Enum.all?(profiles, fn {name, config} ->
               is_binary(name) and byte_size(name) in 1..100 and
                 not String.starts_with?(name, "scheduled/") and match?(%Alto.Config{}, config)
             end),
           do:
             raise(
               ArgumentError,
               "profiles must map names to Alto.Config values; scheduled/ is reserved"
             )

    unless is_integer(retention) and retention in 1..100_000,
      do: raise(ArgumentError, "max_retained_events must be between 1 and 100000")

    %__MODULE__{
      workspace: workspace,
      state_dir: state_dir,
      profiles: profiles,
      max_retained_events: retention,
      runtime: runtime,
      workspaces: workspaces,
      mailbox: mailbox,
      scheduling: scheduling
    }
  end

  defp workspace_options(options) do
    defaults = [max_retained: 128, max_log_bytes: 64_000_000]

    unless Keyword.keyword?(options) and Keyword.keys(options) -- Keyword.keys(defaults) == [],
      do: raise(ArgumentError, "invalid workspace options")

    settings = Keyword.merge(defaults, options)

    unless is_integer(settings[:max_retained]) and settings[:max_retained] in 1..10_000 and
             is_integer(settings[:max_log_bytes]) and
             settings[:max_log_bytes] in 100_000..256_000_000,
           do: raise(ArgumentError, "invalid workspace retention limits")

    settings
  end

  defp mailbox_options(options) do
    defaults = [
      auto_compact: true,
      max_messages: 1_000,
      max_completed: 10_000,
      lease_ms: 30_000,
      max_log_bytes: 64_000_000
    ]

    bounds = [
      max_messages: 1..10_000,
      max_completed: 1..100_000,
      lease_ms: 1_000..3_600_000,
      max_log_bytes: 64_000..256_000_000
    ]

    unless Keyword.keyword?(options) and Keyword.keys(options) -- Keyword.keys(defaults) == [],
      do: raise(ArgumentError, "invalid mailbox options")

    settings = Keyword.merge(defaults, options)

    unless is_boolean(settings[:auto_compact]),
      do: raise(ArgumentError, "invalid mailbox auto_compact")

    Enum.each(bounds, fn {key, range} ->
      unless is_integer(settings[key]) and settings[key] in range,
        do: raise(ArgumentError, "invalid mailbox #{key}")
    end)

    settings
  end

  defp scheduling_options(options) do
    defaults = [
      workers: 2,
      max_attempts: 3,
      poll_ms: 250,
      run_timeout: 300_000,
      max_model_requests: 64,
      max_effects: 1_000,
      max_pending: 100,
      max_tasks: 1_000
    ]

    bounds = [
      workers: 1..16,
      max_attempts: 1..32,
      poll_ms: 10..60_000,
      run_timeout: 100..86_400_000,
      max_model_requests: 1..10_000,
      max_effects: 1..100_000,
      max_pending: 1..100,
      max_tasks: 1..10_000
    ]

    unless Keyword.keyword?(options) and Keyword.keys(options) -- Keyword.keys(defaults) == [],
      do: raise(ArgumentError, "invalid scheduling options")

    settings = Keyword.merge(defaults, options)

    Enum.each(bounds, fn {key, range} ->
      unless is_integer(settings[key]) and settings[key] in range,
        do: raise(ArgumentError, "invalid scheduling #{key}")
    end)

    settings
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
