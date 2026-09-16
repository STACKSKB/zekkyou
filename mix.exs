defmodule Zekkyou.MixProject do
  use Mix.Project

  def project do
    [
      app: :zekkyou,
      version: "0.0.1-dev",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      escript: [main_module: Zekkyou.CLI],
      releases: [
        zekkyou: [
          include_executables_for: [:unix],
          include_src: false,
          steps: [:assemble, &package_service/1, :tar]
        ]
      ],
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto], mod: {Zekkyou.Application, []}]
  end

  defp package_service(release) do
    files =
      for source <- ["deploy", "examples", "docs", "README.md", "ROADMAP.md", "VALIDATION.md"],
          path <- File.cp_r!(source, Path.join(release.path, source)),
          File.regular?(path),
          do: Path.relative_to(path, release.path)

    %{release | overlays: release.overlays ++ files}
  end

  defp deps do
    alto =
      case System.get_env("ALTO_PATH") do
        nil ->
          {:alto,
           git: "https://github.com/STACKSKB/alto.git",
           ref: "8feb1000cd105352566f8612425b842fb3014822"}

        path ->
          {:alto, path: Path.expand(path)}
      end

    [alto]
  end
end
