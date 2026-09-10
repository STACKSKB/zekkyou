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
           ref: "8ecceaf3a84831c15616b71016b9f7ac52ed3f95"}

        path ->
          {:alto, path: Path.expand(path)}
      end

    [alto]
  end
end
