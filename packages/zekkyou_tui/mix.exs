defmodule ZekkyouTUI.MixProject do
  use Mix.Project

  def project do
    [
      app: :zekkyou_tui,
      version: "0.0.1-dev",
      elixir: "~> 1.18",
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    ref = "d5c7de2c99f85f6ab0498de8863eae78ef10e6e8"
    repository = "https://github.com/STACKSKB/alto.git"

    {alto, alto_tui} =
      case System.get_env("ALTO_PATH") do
        nil ->
          {{:alto, git: repository, ref: ref, override: true},
           {:alto_tui, git: repository, ref: ref, subdir: "packages/alto_tui", override: true}}

        path ->
          path = Path.expand(path)

          {{:alto, path: path, override: true},
           {:alto_tui, path: Path.join(path, "packages/alto_tui"), override: true}}
      end

    [
      {:zekkyou, path: "../..", override: true},
      alto,
      alto_tui,
      {:ex_ratatui, "~> 0.13.1", override: true}
    ]
  end
end
