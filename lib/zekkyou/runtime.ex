defmodule Zekkyou.Runtime do
  @moduledoc "Server-side adapter for resident execution and its transport."

  @callback children(Zekkyou.Config.t(), term()) :: [Supervisor.child_spec()]
end
