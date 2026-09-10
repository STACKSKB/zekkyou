defmodule Zekkyou.Release do
  @moduledoc "Entry point for the bundled service and CLI, without Mix or system Elixir."

  def main(args) do
    case Application.ensure_all_started(:zekkyou, :permanent) do
      {:ok, _applications} ->
        Zekkyou.CLI.main(args)

      {:error, reason} ->
        IO.puts(:stderr, "Zekkyou could not start: #{inspect(reason)}")
        System.halt(1)
    end
  end
end
