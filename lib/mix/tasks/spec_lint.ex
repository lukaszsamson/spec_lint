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

  alias Mix.Dep.ElixirSCM
  alias Mix.Dep.Loader, as: DepLoader
  alias SpecLint.{BuildRecord, CLI, Compiler, Config, Explain, Project, Report, Run}
  alias SpecLint.BuildRecord.Capture
  alias SpecLint.Report.Json

  # What a compilation records (`record_build!/4`): per owned application
  # the artifacts already verified for this build and pipeline (`prior`)
  # and its compiler list (`pipelines`), and the snapshots of the verified
  # dependencies inferred from (`dependencies`). `force?` says whether the
  # compile must be forced. Shared by owned applications and dependencies.
  @typep plan :: %{
           force?: boolean(),
           prior: %{atom() => map()},
           dependencies: %{String.t() => map()},
           pipelines: %{atom() => [atom()]}
         }

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
    capabilities = compiler_capabilities()
    project = Project.current()
    plan = compile_plan!(project, capabilities)
    args = if plan.force?, do: ["--force", "--return-errors"], else: ["--return-errors"]
    if plan.force?, do: reenable_compile()

    compile_and_record!(args, capabilities, plan)
    :ok
  end

  defp compiler_capabilities do
    case Compiler.preflight_once() do
      {:ok, capabilities} -> capabilities
      {:error, _reason} -> nil
    end
  end

  @spec compile_plan!(Project.t(), Compiler.capabilities() | nil) :: plan()
  defp compile_plan!(_project, nil),
    do: %{force?: false, prior: %{}, dependencies: %{}, pipelines: %{}}

  defp compile_plan!(project, capabilities) do
    pipelines = check_compiler_pipeline!()
    {dependencies_changed?, dependencies} = compile_dependencies!(project, capabilities)
    plan(project, capabilities, pipelines, dependencies, dependencies_changed?)
  end

  # After the dependencies `project` infers from are compiled and recorded:
  # the evidence verified under the current pipeline is read before the
  # compile, and the compile is forced when a record is stale or a
  # dependency was rebuilt.
  @spec plan(Project.t(), Compiler.capabilities(), map(), map(), boolean()) :: plan()
  defp plan(project, capabilities, pipelines, dependencies, dependencies_changed?) do
    prior =
      Map.new(project.apps, fn app ->
        {app.app, BuildRecord.verified_beams(app, capabilities, pipeline!(pipelines, app))}
      end)

    stale? = stale_build?(project, capabilities, pipelines)

    if dependencies_changed? and not stale? do
      Enum.each(project.apps, fn app ->
        Mix.shell().info(
          "spec_lint: recompiling #{app.app} with #{capabilities.adapter_id}: dependency signatures rebuilt"
        )
      end)
    end

    %{
      force?: stale? or dependencies_changed?,
      prior: prior,
      dependencies: dependencies,
      pipelines: pipelines
    }
  end

  defp pipeline!(pipelines, app) do
    case Map.fetch(pipelines, app.app) do
      {:ok, compilers} ->
        compilers

      :error ->
        Mix.raise("unsupported compiler pipeline: no compiler list for #{app.app}",
          exit_status: 2
        )
    end
  end

  # Compiler events identify modules, not output bytes. A custom compiler
  # after :erlang can replace an earlier compiler's output from a cache
  # without publishing an event, and final-file digests would then attest
  # the wrong producer. Custom stages before :erlang are supported (see
  # "Supported compiler pipelines" in SpecLint.BuildRecord). Returns the
  # compiler list of every application compiled here, keyed like the
  # applications of `SpecLint.Project.current/0`, for its record.
  defp check_compiler_pipeline! do
    compilers = check_project_pipeline!()

    if Mix.Project.umbrella?() do
      Map.new(Enum.sort(Mix.Project.apps_paths() || %{}), fn {app, path} ->
        {app, Mix.Project.in_project(app, path, fn _ -> check_project_pipeline!() end)}
      end)
    else
      %{Mix.Project.config()[:app] => compilers}
    end
  end

  # The checks for the current Mix project (the umbrella root, a child or
  # a dependency); returns its compiler list.
  defp check_project_pipeline! do
    compilers = Mix.Task.Compiler.compilers()
    name = Mix.Project.config()[:app] || "umbrella"

    with :ok <- check_pipeline_shape(compilers),
         :ok <- check_compile_aliases(),
         :ok <- check_builtin_tasks() do
      compilers
    else
      {:error, reason} ->
        Mix.raise("unsupported compiler pipeline for #{name}: #{reason}", exit_status: 2)
    end
  end

  defp check_pipeline_shape(compilers) do
    case BuildRecord.check_pipeline(compilers) do
      :ok -> :ok
      {:error, reason} -> {:error, "#{inspect(compilers)}: #{reason}"}
    end
  end

  defp builtin_tasks,
    do: ["compile", "compile.all" | Enum.map(BuildRecord.builtin_stages(), &"compile.#{&1}")]

  # Prefix-stage aliases run at the stage's position like compiler tasks.
  # Built-in tasks accept only a single self-invocation with options that
  # affect diagnostics, never emitted artifacts or compilation. Mix passes
  # caller arguments (including SpecLint's --force) to that self-invocation.
  # Multiple steps are refused: Mix clears caller arguments after the first
  # self-invocation, so later steps would not receive --force.
  @self_alias_flags ~w(--warnings-as-errors --no-all-warnings)

  defp check_compile_aliases do
    aliases = Mix.Project.config()[:aliases] || []

    case Enum.find(builtin_tasks(), &replacing_alias?(aliases, &1)) do
      nil ->
        :ok

      task ->
        {:error,
         "alias #{task} can replace compiler output; compiler provenance requires " <>
           "Mix's built-in compile tasks (only one self-invocation with " <>
           "--warnings-as-errors or --no-all-warnings is accepted)"}
    end
  end

  defp replacing_alias?(aliases, task) do
    case Keyword.fetch(aliases, String.to_atom(task)) do
      :error ->
        false

      {:ok, [step]} ->
        not self_step?(step, task)

      {:ok, _other} ->
        true
    end
  end

  defp self_step?(step, task) when is_binary(step) do
    case OptionParser.split(step) do
      [^task | flags] ->
        Enum.all?(flags, &(&1 in @self_alias_flags)) and
          length(flags) == length(Enum.uniq(flags))

      _other ->
        false
    end
  rescue
    _error in [ArgumentError, RuntimeError] -> false
  end

  defp self_step?(_step, _task), do: false

  defp check_builtin_tasks do
    mix_ebin = Path.join(List.to_string(:code.lib_dir(:mix)), "ebin")

    replaced =
      Enum.find(builtin_tasks(), fn task ->
        module = Mix.Task.get(task)

        module == nil or
          :code.which(module) != String.to_charlist(Path.join(mix_ebin, "#{module}.beam"))
      end)

    if replaced,
      do: {:error, "task #{replaced} is not Mix's built-in task"},
      else: :ok
  end

  defp compile_and_record!(args, capabilities, plan) do
    capture = if capabilities, do: Capture.start()

    try do
      "compile"
      |> Mix.Task.run(args)
      |> check_compile!(plan.force?)

      if capabilities do
        compiled = Capture.finish(capture)
        check_dependencies!(Project.current(), capabilities)
        record_build!(Project.current(), capabilities, plan, compiled)
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

  # Dependency checker signatures participate in inference even when the
  # compiler version/chunk number and BEAM code MD5 are unchanged. Compile
  # dependencies in topological order, preserving orphans, and attest every
  # artifact before any owned application is inferred from those signatures.
  defp compile_dependencies!(project, capabilities) do
    owned = MapSet.new(project.apps, & &1.app)

    check_dependency_api!()

    Mix.Dep.cached()
    |> Enum.reject(&MapSet.member?(owned, &1.app))
    |> Enum.reduce({false, %{}}, &compile_dependency!(&1, &2, capabilities))
  rescue
    error ->
      Enum.each(project.apps, &File.rm(BuildRecord.path(&1)))
      reraise error, __STACKTRACE__
  end

  defp compile_dependency!(dep, {upstream_changed?, snapshots}, capabilities) do
    if Mix.Dep.mix?(dep) and is_nil(dep.opts[:compile]) do
      {changed?, snapshots} =
        DepLoader.with_system_env(dep, fn ->
          compile_in_dependency!(dep, upstream_changed?, snapshots, capabilities)
        end)

      if changed?, do: touch_fetchable(dep)
      {changed?, snapshots}
    else
      check_external_dependency!(dep)
      {upstream_changed?, snapshots}
    end
  end

  # What deps.compile does after compiling a fetchable dependency: it
  # rewrites the dependency's SCM manifest. Since 1.21 the compiler writes
  # that manifest without the dependency list, which deps.compile completes
  # (`update/4`); otherwise the next Mix command sees the dependency as
  # outdated, deletes its build directory (and record) and recompiles it.
  # Elixir 1.20 stores no dependency list (`update/3`). The private API is
  # checked by `check_dependency_api!/0` and called through a variable
  # module, so each compiler line compiles only the arity it has.
  # deps.compile then also runs `will_recompile`, which makes the root
  # project recompile; spec_lint already forces owned applications to
  # recompile after any dependency changed (`plan/5`).
  defp touch_fetchable(dep, scm_manifest \\ ElixirSCM) do
    if dep.scm.fetchable?() do
      manifest = Path.join(dep.opts[:build], ".mix")

      if function_exported?(scm_manifest, :update, 4) do
        scm_manifest.update(manifest, dep.scm, dep.opts[:lock], Enum.map(dep.deps, & &1.app))
      else
        scm_manifest.update(manifest, dep.scm, dep.opts[:lock])
      end
    end
  end

  defp compile_in_dependency!(dep, upstream_changed?, snapshots, capabilities) do
    Mix.Dep.in_dependency(dep, fn _ ->
      compile_mix_dependency!(upstream_changed?, snapshots, capabilities)
    end)
  end

  defp compile_mix_dependency!(upstream_changed?, snapshots, capabilities) do
    pipelines = check_compiler_pipeline!()
    dependency = Project.current()
    plan = plan(dependency, capabilities, pipelines, snapshots, upstream_changed?)
    reenable_compile()

    args = [
      "--return-errors",
      "--from-mix-deps-compile",
      "--no-deps-check",
      "--no-warnings-as-errors",
      "--no-code-path-pruning"
    ]

    args = if plan.force?, do: ["--force" | args], else: args
    capture = Capture.start()

    try do
      result = Mix.Task.run("compile", args)
      check_compile!(result, plan.force?)
      compiled = Capture.finish(capture)
      check_dependency_build!(dependency)
      record_build!(dependency, capabilities, plan, compiled)

      changed? =
        plan.force? or Enum.any?(compiled, fn {_app, modules} -> MapSet.size(modules) > 0 end)

      {changed?, dependency_snapshots(dependency, snapshots)}
    after
      Capture.stop(capture)
    end
  end

  defp dependency_snapshots(dependency, snapshots) do
    Enum.reduce(dependency.apps, snapshots, fn app, acc ->
      Map.put(acc, Atom.to_string(app.app), BuildRecord.snapshot(app))
    end)
  end

  defp check_dependency_build!(project) do
    case Project.check_build_paths(project) do
      :ok ->
        :ok

      error ->
        apps = Enum.map_join(project.apps, ", ", &Atom.to_string(&1.app))
        Mix.raise("incomplete dependency build for #{apps}: #{inspect(error)}", exit_status: 2)
    end
  end

  defp check_dependency_api! do
    required = [
      {Mix.Dep, :cached, 0},
      {Mix.Dep, :mix?, 1},
      {Mix.Dep, :in_dependency, 2},
      {Mix.Dep.Loader, :with_system_env, 2},
      # update/4 (with the dependency list) since 1.21, update/3 in 1.20.
      [{ElixirSCM, :update, 4}, {ElixirSCM, :update, 3}]
    ]

    for alternatives <- required,
        alternatives = List.wrap(alternatives),
        not Enum.any?(alternatives, &exported?/1) do
      names = Enum.map_join(alternatives, " or ", fn {m, f, a} -> "#{inspect(m)}.#{f}/#{a}" end)
      Mix.raise("dependency compiler evidence API is unavailable: #{names}", exit_status: 2)
    end

    :ok
  end

  defp exported?({module, function, arity}),
    do: Code.ensure_loaded?(module) and function_exported?(module, function, arity)

  defp check_external_dependency!(dep) do
    ebin = Path.join(dep.opts[:build], "ebin")

    if BuildRecord.elixir_artifacts?(ebin) do
      Mix.raise(
        "cannot verify compiler provenance for dependency #{dep.app}: " <>
          "artifacts with Elixir metadata or unreadable BEAMs require a source-backed " <>
          "Mix dependency with the built-in " <>
          "compiler pipeline, without a custom :compile command",
        exit_status: 2
      )
    end
  end

  defp check_dependencies!(project, capabilities) do
    owned = MapSet.new(project.apps, & &1.app)

    Mix.Dep.cached()
    |> Enum.reject(&MapSet.member?(owned, &1.app))
    |> Enum.each(fn dep ->
      app = %{app: dep.app, ebin: Path.join(dep.opts[:build], "ebin")}

      if BuildRecord.elixir_artifacts?(app.ebin) and
           BuildRecord.status(app, capabilities) != :verified do
        Enum.each(project.apps, &File.rm(BuildRecord.path(&1)))

        Mix.raise(
          "cannot verify compiler provenance for dependency #{dep.app} after compilation; " <>
            "its Elixir artifacts are not verified for the running compiler build",
          exit_status: 2
        )
      end
    end)
  end

  defp stale_build?(project, capabilities, pipelines) do
    stale =
      for app <- project.apps,
          (status = BuildRecord.status(app, capabilities, pipeline!(pipelines, app))) !=
            :verified,
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

  @spec record_build!(Project.t(), Compiler.capabilities(), plan(), %{atom() => MapSet.t()}) ::
          :ok
  defp record_build!(project, capabilities, plan, compiled) do
    for app <- project.apps, File.dir?(app.ebin) do
      evidence =
        Map.merge(
          Map.get(plan.prior, app.app, %{}),
          BuildRecord.compiled_beams(app, Map.get(compiled, app.app, MapSet.new()))
        )

      compilers = pipeline!(plan.pipelines, app)

      case BuildRecord.write(app, capabilities, evidence, plan.dependencies, compilers) do
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
