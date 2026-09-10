defmodule Zekkyou.MixProject do
  use Mix.Project

  def project do
    [
      app: :zekkyou,
      version: "0.0.1-dev",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      escript: [main_module: Zekkyou.CLI],
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto], mod: {Zekkyou.Application, []}]
  end

  defp deps do
    alto =
      case System.get_env("ALTO_PATH") do
        nil ->
          {:alto,
           git: "https://github.com/STACKSKB/alto.git",
           ref: "711aee97db68b5ed50ddae3a55b61c3d16bf92b1"}

        path ->
          {:alto, path: Path.expand(path)}
      end

    [alto]
  end
end
