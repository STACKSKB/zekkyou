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
    alto_path =
      System.get_env("ALTO_PATH") ||
        Mix.raise("zekkyou_tui requires ALTO_PATH until Alto is published")

    [
      {:zekkyou, path: "../..", override: true},
      {:alto, path: Path.expand(alto_path), override: true},
      {:alto_tui, path: Path.join(Path.expand(alto_path), "packages/alto_tui"), override: true},
      {:ex_ratatui, "~> 0.13.1", override: true}
    ]
  end
end
