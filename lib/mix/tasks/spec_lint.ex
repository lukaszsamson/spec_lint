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
  application. Compiler checks and type rendering may load project modules,
  invoking generated metadata functions and `@on_load` callbacks
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
  unsupported compiler or backend in CI, an incomplete run, or an internal
  failure (no report is written then). An existing but empty build
  directory is a project with zero specs: exit 0, and the report says "0
  specs checked".

  With `--output`, a file already at that path is removed before the run
  starts and the new report is written atomically at the end, so a run
  that fails before its report, or a VM killed from outside, leaves no
  report there. A VM killed from outside (a signal, the out-of-memory
  killer) cannot exit 2; CI must treat a missing report, or one whose
  `completion.status` is not `complete`, as a failure.
  """

  use Mix.Task

  alias SpecLint.{BuildRecord, CLI, Compiler, Config, Explain, Project, Report, Run}
  alias SpecLint.BuildRecord.Capture
  alias SpecLint.Report.Json

  @impl true
  @spec run([String.t()]) :: :ok
  def run(argv) do
    cli = ok!(CLI.parse(argv))
    if cli.explain == nil, do: remove_previous_report!(cli.output)

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

    project = Project.current()
    if capabilities, do: check_compiler_pipeline!()

    prior =
      if capabilities,
        do: Map.new(project.apps, &{&1.app, BuildRecord.verified_beams(&1, capabilities)}),
        else: %{}

    force? = capabilities != nil and stale_build?(project, capabilities)
    args = if force?, do: ["--force", "--return-errors"], else: ["--return-errors"]
    if force?, do: reenable_compile()

    compile_and_record!(args, force?, capabilities, prior)
    :ok
  end

  # Compiler events identify modules, not output bytes. A custom compiler
  # can replace an earlier compiler's output from a cache without publishing
  # an event. Final-file digests would then attest the wrong producer.
  defp check_compiler_pipeline! do
    check_current_compilers!()

    if Mix.Project.umbrella?() do
      Enum.each(Enum.sort(Mix.Project.apps_paths() || %{}), fn {app, path} ->
        Mix.Project.in_project(app, path, fn _ -> check_current_compilers!() end)
      end)
    end
  end

  defp check_current_compilers! do
    compilers = Mix.Task.Compiler.compilers()
    supported = [:yecc, :leex, :erlang, :elixir, :app]

    unless compilers == supported do
      Mix.raise(
        "unsupported compiler pipeline for #{Mix.Project.config()[:app] || "umbrella"}: " <>
          "#{inspect(compilers)}; compiler provenance requires Mix's built-in compilers " <>
          "with every default stage in order because compiler events do not attest output bytes",
        exit_status: 2
      )
    end

    tasks = ["compile", "compile.all" | Enum.map(supported, &"compile.#{&1}")]
    aliases = Mix.Project.config()[:aliases] || []

    Enum.each(tasks, fn task ->
      if Keyword.has_key?(aliases, String.to_atom(task)) do
        Mix.raise(
          "unsupported compiler pipeline for #{Mix.Project.config()[:app] || "umbrella"}: " <>
            "alias #{task} can replace compiler output; compiler provenance requires " <>
            "Mix's built-in compile tasks",
          exit_status: 2
        )
      end

      module = Mix.Task.get(task)
      expected = Path.join([List.to_string(:code.lib_dir(:mix)), "ebin", "#{module}.beam"])

      unless module != nil and :code.which(module) == String.to_charlist(expected) do
        Mix.raise(
          "unsupported compiler pipeline: task #{task} is not Mix's built-in task",
          exit_status: 2
        )
      end
    end)
  end

  defp compile_and_record!(args, force?, capabilities, prior) do
    capture = if capabilities, do: Capture.start()

    try do
      "compile"
      |> Mix.Task.run(args)
      |> check_compile!(force?)

      if capabilities do
        compiled = Capture.finish(capture)
        check_dependencies!(Project.current(), capabilities)
        record_build!(Project.current(), capabilities, prior, compiled)
      end
    after
      if capture, do: Capture.stop(capture)
    end
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

  defp record_build!(project, capabilities, prior, compiled) do
    for app <- project.apps, File.dir?(app.ebin) do
      evidence =
        Map.merge(
          Map.get(prior, app.app, %{}),
          BuildRecord.compiled_beams(app, Map.get(compiled, app.app, MapSet.new()))
        )

      case BuildRecord.write(app, capabilities, evidence) do
        :ok ->
          :ok

        {:error, {:unverified_beams, files}} ->
          Mix.raise(
            "cannot verify compiler provenance for #{app.app}: " <>
              Enum.join(files, ", ") <>
              "; these BEAM files were not produced by this compilation or previously " <>
              "verified for the running build. Rebuild their sources or remove the stale " <>
              "artifacts explicitly",
            exit_status: 2
          )

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
    case internal!(fn -> Explain.render(run, mfa) end) do
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
        text = internal!(fn -> Report.render(run, :console) end)
        :ok = write_output!(cli.output, text)
        Mix.shell().info(text)

      :json ->
        json = internal!(fn -> Report.render(run, :json) end)

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

  # A report file left by an earlier run is removed before this one starts,
  # so a run that ends without writing one (exit 2 before the report, or a
  # VM killed from outside) leaves no complete report at the path. The
  # report itself is written atomically (`Json.write_atomic/2`).
  defp remove_previous_report!(nil), do: :ok

  defp remove_previous_report!(path) do
    case File.rm(path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Mix.raise(
          "cannot remove the previous report #{path}: #{:file.format_error(reason)}",
          exit_status: 2
        )
    end
  end

  # An exception, throw or exit while rendering is an internal failure
  # (exit 2), never the exit status 1 Mix gives an uncaught exception, which
  # CI reads as findings.
  defp internal!(fun) do
    fun.()
  rescue
    error in Mix.Error ->
      reraise error, __STACKTRACE__

    error ->
      Mix.raise("internal failure: " <> Exception.message(error), exit_status: 2)
  catch
    :throw, value ->
      Mix.raise("internal failure: uncaught throw " <> inspect(value), exit_status: 2)

    :exit, reason ->
      Mix.raise("internal failure: exit " <> inspect(reason), exit_status: 2)
  end

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
