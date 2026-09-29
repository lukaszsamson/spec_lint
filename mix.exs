defmodule SpecLint.MixProject do
  use Mix.Project

  def project do
    [
      app: :spec_lint,
      version: "0.1.0",
      description: "Checks Elixir @spec declarations against compiler-inferred signatures",
      source_url: "https://github.com/lukaszsamson/spec_lint",
      package: package(),
      elixir: "~> 1.20.4 or ~> 1.21-dev",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      dialyzer: [
        plt_add_apps: [:mix],
        # SPEC_LINT_PLT_DIR keeps the PLTs of another Elixir build (the
        # upstream toolchain qualification) apart: both are 1.21.0-dev, so
        # their PLT file names are the same.
        plt_core_path: plt_dir(),
        plt_local_path: plt_dir(),
        flags: [:unmatched_returns, :error_handling, :underspecs]
      ]
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/lukaszsamson/spec_lint"},
      files: [
        "lib",
        "mix.exs",
        ".formatter.exs",
        "README.md",
        "DESIGN.md",
        "RELEASE.md",
        "LICENSE",
        "NOTICE",
        "THIRD_PARTY_NOTICES.md"
      ]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp plt_dir, do: System.get_env("SPEC_LINT_PLT_DIR", "priv/plts")

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
