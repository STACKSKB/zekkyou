defmodule Zekkyou.Runtime.Alto do
  @moduledoc "Composes Alto's resident registry and Unix socket transport."
  @behaviour Zekkyou.Runtime

  @impl true
  def children(config, name) do
    registry = Zekkyou.Service.component(name, :runtime)

    {stores, workers} = Zekkyou.Tasks.children(config, name)

    stores ++
      [
        {Alto.FrontEnd.Registry,
         name: registry,
         config_resolver: &Zekkyou.Tasks.resolve(config, &1),
         commands: Zekkyou.Tasks.commands(name),
         max_active_runs: config.scheduling[:workers] + 2,
         cwd: config.workspace,
         sessions: [session_dir: Path.join(config.state_dir, "sessions")],
         max_retained_events: config.max_retained_events}
      ] ++
      workers ++
      [
        {Alto.Listeners.UnixSocket,
         name: Zekkyou.Service.component(name, :socket),
         registry: registry,
         path: Zekkyou.Config.socket_path(config)}
      ]
  end
end
