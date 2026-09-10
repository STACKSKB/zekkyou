defmodule Zekkyou.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Zekkyou.ProcessRegistry},
      {DynamicSupervisor, name: Zekkyou.Services, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Zekkyou.Supervisor)
  end
end
