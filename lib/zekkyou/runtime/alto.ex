defmodule Zekkyou.Runtime.Alto do
  @moduledoc "Composes Alto's resident registry and Unix socket transport."
  @behaviour Zekkyou.Runtime

  @impl true
  def children(config, name) do
    registry = Zekkyou.Service.component(name, :runtime)

    [
      {Alto.FrontEnd.Registry,
       name: registry,
       config_resolver: &Zekkyou.Config.resolve(config, &1),
       cwd: config.workspace,
       sessions: [session_dir: Path.join(config.state_dir, "sessions")],
       max_retained_events: config.max_retained_events},
      {Alto.Listeners.UnixSocket,
       name: Zekkyou.Service.component(name, :socket),
       registry: registry,
       path: Zekkyou.Config.socket_path(config)}
    ]
  end
end
