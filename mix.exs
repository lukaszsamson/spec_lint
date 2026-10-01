defmodule SpecLint.MixProject do
  use Mix.Project

  def project do
    [
      app: :spec_lint,
      version: "0.1.0",
      description: "Checks Elixir @spec declarations against compiler-inferred signatures",
      source_url: "https://github.com/lukaszsamson/spec_lint",
      package: [
        licenses: ["Apache-2.0"],
        links: %{"GitHub" => "https://github.com/lukaszsamson/spec_lint"},
        files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE NOTICE THIRD_PARTY_NOTICES.md)
      ],
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      dialyzer: [plt_add_apps: [:mix], flags: [:unmatched_returns, :error_handling]]
    ]
  end

  def application, do: []

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
