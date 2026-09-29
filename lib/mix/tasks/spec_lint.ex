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
  `Mix.Task.run("compile")` (see `compile!/0`: with `--force` when the
  build was not produced by the running compiler). It never starts the
  application, and its analysis never invokes project functions
  (compilation runs macros).
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
    * `--[no-]clause-local-qualification` - qualify an SL001 clause
      conflict by the containment of its clause domain in the spec's
      argument lower bounds instead of the slice-wide arrow prerequisites
      (default `true`; `--no-clause-local-qualification` restores the
      slice-wide prerequisites)

  Exit status: `0` accepted; `1` new gated findings or a coverage violation
  (with `--ci` or `--warnings-as-errors`); `2` invalid options or
  configuration (including an explicit baseline path that does not exist),
  compilation failure, a missing build directory for an owned application
  or one missing BEAM files its build lists, BEAM files produced by another
  compiler build, dependencies compiled by another compiler line,
  unsupported compiler or backend in CI, or an incomplete run. An existing but empty build
  directory is a project with zero specs: exit 0, and the report says "0
  specs checked".
  """

  use Mix.Task

  alias SpecLint.{BuildRecord, CLI, Compiler, Config, Explain, Project, Report, Run}
  alias SpecLint.Report.Json

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

  Two builds of the same Elixir version (the qualified `1.21.0-dev`
  revisions) do not make Mix recompile, so the BEAM files may come from
  another compiler build than the running one. When the running compiler
  is supported, the compile is forced (`--force`) unless the
  `SpecLint.BuildRecord` of every owned application says the running
  build produced its current BEAM files, and a new record is written
  afterwards.

  `Mix.Task.run/2` does nothing when `compile` already ran in this VM
  (`mix do compile + spec_lint`, an alias such as
  `["compile", "spec_lint --ci"]`, or a task defined in the project
  itself, which Mix compiles to find it). A forced compile therefore
  re-enables the compile tasks first, and a forced compile that still
  compiled nothing is an error (exit 2) that writes no record: recording
  it would name the running build as the producer of the other build's
  BEAM files.
  """
  @spec compile!() :: :ok
  def compile! do
    capabilities =
      case Compiler.preflight_once() do
        {:ok, capabilities} -> capabilities
        {:error, _reason} -> nil
      end

    force? = capabilities != nil and stale_build?(Project.current(), capabilities)
    args = if force?, do: ["--force", "--return-errors"], else: ["--return-errors"]
    if force?, do: reenable_compile()

    "compile"
    |> Mix.Task.run(args)
    |> check_compile!(force?)

    if capabilities do
      check_dependencies!(Project.current(), capabilities)
      record_build!(Project.current(), capabilities)
    end

    :ok
  end

  defp check_compile!({:error, _diagnostics}, _force?),
    do: Mix.raise("compilation failed; spec_lint needs a compiled project", exit_status: 2)

  defp check_compile!(result, true) do
    if noop?(result) do
      Mix.raise(
        "the build was compiled by another compiler, and the forced recompilation " <>
          "did not run (compile already ran in this VM); run mix compile --force, " <>
          "or mix spec_lint on its own",
        exit_status: 2
      )
    end
  end

  defp check_compile!(_result, false), do: :ok

  # The compile chain Mix.Task.run/2 would skip after an earlier compile in
  # this VM: `compile`, `compile.all` and every compiler of the project.
  defp reenable_compile do
    compilers = for compiler <- Mix.Task.Compiler.compilers(), do: "compile.#{compiler}"
    Enum.each(["compile", "compile.all" | compilers], &Mix.Task.reenable/1)
  end

  defp noop?(:noop), do: true
  defp noop?({:noop, _diagnostics}), do: true
  defp noop?(_result), do: false

  # Dependencies compiled by another compiler line (another checker chunk
  # version): the project's signatures were inferred without theirs. The
  # owned records are removed, so the project is recompiled once the
  # dependencies are (Mix does not recompile a caller for a runtime
  # dependency).
  defp check_dependencies!(project, capabilities) do
    owned = for app <- project.apps, do: app.app
    build = Mix.Project.build_path()

    ebins =
      for {app, _source} <- Enum.sort(Mix.Project.deps_paths()),
          app not in owned,
          ebin = Path.join([build, "lib", Atom.to_string(app), "ebin"]),
          File.dir?(ebin),
          do: {app, ebin}

    case BuildRecord.foreign_dependencies(ebins, capabilities) do
      [] ->
        :ok

      foreign ->
        Enum.each(project.apps, &File.rm(BuildRecord.path(&1)))

        list =
          Enum.map_join(foreign, ", ", fn {app, versions} ->
            "#{app} (#{Enum.join(versions, ", ")})"
          end)

        Mix.raise(
          "dependencies compiled by another compiler line: #{list}; the running compiler " <>
            "(#{capabilities.adapter_id}) writes #{capabilities.checker_version} and ignores " <>
            "their signatures. Recompile them (mix deps.compile --force) and run again",
          exit_status: 2
        )
    end
  end

  defp stale_build?(project, capabilities) do
    stale =
      for app <- project.apps,
          (status = BuildRecord.status(app, capabilities)) != :verified,
          do: {app, status}

    for {app, status} <- stale, File.dir?(app.ebin) do
      reason =
        case status do
          :unrecorded -> "no record of the compiler build that produced it"
          mismatch -> BuildRecord.describe(mismatch)
        end

      Mix.shell().info(
        "spec_lint: recompiling #{app.app} with #{capabilities.adapter_id}: #{reason}"
      )
    end

    stale != []
  end

  defp record_build!(project, capabilities) do
    for app <- project.apps, File.dir?(app.ebin) do
      case BuildRecord.write(app, capabilities) do
        :ok ->
          :ok

        {:error, reason} ->
          Mix.raise(
            "cannot write #{BuildRecord.path(app)}: #{:file.format_error(reason)}",
            exit_status: 2
          )
      end
    end

    :ok
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
        text = Report.render(run, :console)
        :ok = write_output!(cli.output, text)
        Mix.shell().info(text)

      :json ->
        json = Report.render(run, :json)

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
