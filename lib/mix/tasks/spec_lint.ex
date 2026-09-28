defmodule Mix.Tasks.SpecLint do
  @shortdoc "Checks @spec declarations against the types the compiler infers"

  @moduledoc """
  Checks the project's `@spec` declarations against the signatures the
  Elixir compiler infers (see the README and DESIGN.md).

      mix spec_lint                       report findings, never fail on them
      mix spec_lint --ci                  gate new findings (review profile unless configured)
      mix spec_lint --ci --profile soundness
      mix spec_lint --explain MyApp.Store.lookup/1
      mix spec_lint --format json --output spec-lint.json
      mix spec_lint --format json > spec-lint.json

  The task parses its options first, then compiles the project with
  `Mix.Task.run("compile")`. It never starts the application, and its
  analysis never invokes project functions (compilation runs macros).
  With `--format json` and no `--output`, standard output carries only the
  JSON report: compiler progress and the summary line go to standard error.

  ## Options

    * `--ci` - gate findings: exit 1 on new gated findings or coverage
      violations
    * `--profile soundness|review` - evidence policy (default `review`)
    * `--analysis signatures|bodies` - analysis backend (default
      `signatures`; `bodies` is not available in this build and exits 2)
    * `--warnings-as-errors` - gate every reported finding
    * `--format console|json`, `--output PATH` - report format and file
    * `--baseline PATH` - baseline file (default `.spec_lint_baseline.json`,
      which may be missing; an explicit path, here or as `baseline:` in the
      configuration, must exist)
    * `--config PATH` - configuration file (default `.spec_lint.exs`)
    * `--module Mod`, `--app app` - partial run (repeatable)
    * `--explain Mod.fun/arity` - explain one function
    * `--rules ID,...`, `--except ID,...` - select rules by ID or name
    * `--require-static-return` - DESIGN 3.1 step 9 (default `false`)

  Exit status: `0` accepted; `1` new gated findings or a coverage violation
  (with `--ci` or `--warnings-as-errors`); `2` invalid options or
  configuration (including an explicit baseline path that does not exist),
  compilation failure, a missing build directory for an owned application
  or one missing BEAM files its build lists, unsupported compiler or
  backend in CI, or an incomplete run. An existing but empty build
  directory is a project with zero specs: exit 0, and the report says "0
  specs checked".
  """

  use Mix.Task

  alias SpecLint.{CLI, Config, Explain, Project, Run}
  alias SpecLint.Report.{Console, Json}

  @impl true
  @spec run([String.t()]) :: :ok
  def run(argv) do
    cli = ok!(CLI.parse(argv))

    if cli.format == :json and cli.output == nil and cli.explain == nil,
      do: SpecLint.StderrShell.with_shell(&compile!/0),
      else: compile!()

    project = Project.current()
    config = load_config!(project, cli)

    modules = if cli.explain, do: [elem(cli.explain, 0)], else: cli.modules

    run =
      ok!(
        Run.execute(project, config,
          ci: cli.ci,
          modules: modules,
          apps: cli.apps,
          only: cli.only,
          except: cli.except
        )
      )

    if cli.explain, do: explain(run, cli.explain), else: report(run, cli)
  end

  @doc """
  Compiles the project with `Mix.Task.run("compile")`, returning errors
  instead of exiting, and turns a compilation failure into exit status 2
  (the compiler output has already been printed).
  """
  @spec compile!() :: :ok
  def compile! do
    case Mix.Task.run("compile", ["--return-errors"]) do
      {:error, _diagnostics} ->
        Mix.raise("compilation failed; spec_lint needs a compiled project", exit_status: 2)

      _ ->
        :ok
    end
  end

  @doc """
  Loads `.spec_lint.exs` (or `--config`) and applies the command-line
  overrides; any error is exit status 2.
  """
  @spec load_config!(Project.t(), CLI.t()) :: Config.t()
  def load_config!(project, cli) do
    config = ok!(Config.load(project.root, cli.config))
    ok!(Config.merge_cli(config, CLI.config_overrides(cli)))
  end

  defp explain(run, mfa) do
    case Explain.render(run, mfa) do
      {:ok, text} ->
        Mix.shell().info(IO.iodata_to_binary(text))
        halt(if(run.exit_code == 2, do: 2, else: 0))

      {:error, message} ->
        Mix.raise(message, exit_status: 2)
    end
  end

  defp report(run, cli) do
    case cli.format do
      :console ->
        text = IO.iodata_to_binary(Console.render(run))
        :ok = write_output!(cli.output, text)
        Mix.shell().info(text)

      :json ->
        json = Json.encode(Json.envelope(run))

        if cli.output do
          :ok = write_output!(cli.output, json)
          Mix.shell().info(summary(run, cli.output))
        else
          IO.write(json)
          IO.puts(:stderr, summary(run, nil))
        end
    end

    halt(run.exit_code)
  end

  defp summary(run, output) do
    blocking = Enum.count(run.issues, &SpecLint.Issue.blocking?/1)
    target = if output, do: " -> #{output}", else: ""

    specs = get_in(run.ledger, ["functions", "found"]) || 0

    "spec_lint: #{specs} specs checked, #{length(run.issues)} finding(s), " <>
      "#{blocking} gating and new, " <>
      "#{run.completion}, exit #{run.exit_code}#{target}"
  end

  defp ok!({:ok, value}), do: value
  defp ok!({:error, message}), do: Mix.raise(message, exit_status: 2)

  defp write_output!(nil, _data), do: :ok

  defp write_output!(path, data) do
    case Json.write_atomic(path, data) do
      :ok -> :ok
      {:error, message} -> Mix.raise(message, exit_status: 2)
    end
  end

  defp halt(0), do: :ok
  defp halt(code), do: exit({:shutdown, code})
end
