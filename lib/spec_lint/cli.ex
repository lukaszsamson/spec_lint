defmodule SpecLint.CLI do
  @moduledoc """
  Command-line options of `mix spec_lint` and `mix spec_lint.baseline`
  (DESIGN.md section 8), parsed before anything is compiled so an invalid
  option is reported without side effects.

      --ci                         gate findings (exit 1 on new gated findings)
      --profile soundness|review   evidence policy profile (default: review)
      --warnings-as-errors         gate every reported finding
      --format console|json        report format (default: console)
      --output PATH                write the report (or baseline) to PATH
      --baseline PATH              baseline file (default: .spec_lint_baseline.json)
      --config PATH                configuration file (default: .spec_lint.exs)
      --module Mod                 analyse only this module (repeatable; partial run)
      --app app                    analyse only this umbrella child (repeatable; partial run)
      --explain Mod.fun/arity      explain one function
      --rules ID,...               run only these rules (IDs or names)
      --except ID,...              do not run these rules
      --require-static-return      DESIGN 3.1 step 9 (default from config: false)
  """

  alias SpecLint.Explain

  @switches [
    ci: :boolean,
    profile: :string,
    warnings_as_errors: :boolean,
    format: :string,
    output: :string,
    baseline: :string,
    config: :string,
    module: :keep,
    app: :keep,
    explain: :string,
    rules: :string,
    except: :string,
    require_static_return: :boolean
  ]

  @type t :: %{
          ci: boolean(),
          profile: :review | :soundness | nil,
          warnings_as_errors: boolean() | nil,
          format: :console | :json,
          output: String.t() | nil,
          baseline: String.t() | nil,
          config: String.t() | nil,
          modules: [module()],
          apps: [atom()],
          explain: mfa() | nil,
          only: [String.t()] | nil,
          except: [String.t()],
          require_static_return: boolean() | nil
        }

  @doc "Parses `argv`. Every error is a message for exit code 2."
  @spec parse([String.t()]) :: {:ok, t()} | {:error, String.t()}
  def parse(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {opts, [], []} -> build(opts)
      {_opts, rest, []} -> {:error, "unexpected arguments: #{Enum.join(rest, " ")}"}
      {_opts, _rest, invalid} -> {:error, "invalid options: #{format_invalid(invalid)}"}
    end
  end

  defp format_invalid(invalid) do
    Enum.map_join(invalid, ", ", fn
      {option, nil} -> option
      {option, value} -> "#{option} #{value}"
    end)
  end

  defp build(opts) do
    with {:ok, profile} <- profile(opts[:profile]),
         {:ok, format} <- format(opts[:format]),
         {:ok, explain} <- explain(opts[:explain]) do
      {:ok,
       %{
         ci: Keyword.get(opts, :ci, false),
         profile: profile,
         warnings_as_errors: opts[:warnings_as_errors],
         format: format,
         output: opts[:output],
         baseline: opts[:baseline],
         config: opts[:config],
         modules: opts |> Keyword.get_values(:module) |> Enum.map(&module/1),
         apps: opts |> Keyword.get_values(:app) |> Enum.map(&String.to_atom/1),
         explain: explain,
         only: opts[:rules] && list(opts[:rules]),
         except: list(opts[:except] || ""),
         require_static_return: opts[:require_static_return]
       }}
    end
  end

  defp profile(nil), do: {:ok, nil}
  defp profile("review"), do: {:ok, :review}
  defp profile("soundness"), do: {:ok, :soundness}
  defp profile(other), do: {:error, "--profile must be soundness or review, got: #{other}"}

  defp format(nil), do: {:ok, :console}
  defp format("console"), do: {:ok, :console}
  defp format("json"), do: {:ok, :json}
  defp format(other), do: {:error, "--format must be console or json, got: #{other}"}

  defp explain(nil), do: {:ok, nil}
  defp explain(string), do: Explain.parse_mfa(string)

  defp module(":" <> erlang), do: String.to_atom(erlang)
  defp module(elixir), do: Module.concat([elixir])

  defp list(string),
    do: string |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  @doc "Configuration overrides from parsed options, for `SpecLint.Config.merge_cli/2`."
  @spec config_overrides(t()) :: keyword()
  def config_overrides(cli) do
    [
      profile: cli.profile,
      baseline: cli.baseline,
      warnings_as_errors: cli.warnings_as_errors,
      require_static_return: cli.require_static_return
    ]
  end
end
