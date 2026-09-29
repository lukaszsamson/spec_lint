defmodule SpecLint.Run do
  @moduledoc """
  One SpecLint run over a project (DESIGN.md section 5): preflight, BEAM
  discovery, analysis, evidence, rules, coverage, policy and baseline
  decisions, ending in an exit code. It prints nothing and never exits;
  the Mix task maps `exit_code` to the process status at its boundary.

  Exit codes: `0` accepted; `1` new gated findings or a coverage violation
  (only in CI mode or with `warnings_as_errors`); `2` incomplete run
  (internal failure analysing a module, required reachability check failure,
  including a crashed check; unsupported compiler or checker chunk in CI),
  unsupported backend, configuration error.

  Completion is `:complete`, `:partial` (a `--module` or `--app` filter
  was given; stale entries are never declared and the coverage floor is
  not checked) or `:incomplete` (an internal failure, or a checker chunk
  written by another checker version, which fails preflight: exit 2 in CI;
  or a required reachability check failure).

  Coverage (`SL008`) is always evaluated, including slices the baseline
  inventory lists whose function is still exported but lost its spec
  (`SpecLint.Coverage.lost_analysis/2`). When rule selection (`--rules`,
  `--except`, `rules: [analysis_unavailable: :off]`) leaves SL008 out, its
  findings are not reported, but the ones that would block become coverage
  violations, so selecting rules never bypasses the coverage policy. Stale
  baseline findings are declared only for the rules that ran.
  """

  alias SpecLint.{
    Analysis,
    Baseline,
    Beam,
    BuildRecord,
    Compiler,
    Config,
    Coverage,
    Evidence,
    Issue,
    Policy,
    Project,
    Reachability,
    TypeCache
  }

  alias SpecLint.Rules.{AnalysisUnavailable, ReturnConflict}

  @type completion :: :complete | :partial | :incomplete

  @typedoc "Options of `execute/2`."
  @type option ::
          {:ci, boolean()}
          | {:modules, [module()]}
          | {:apps, [atom()]}
          | {:only, [String.t()] | nil}
          | {:except, [String.t()]}
          | {:preflight, {:ok, Compiler.capabilities()} | {:error, term()}}
          | {:today, Date.t()}

  @type t :: %__MODULE__{
          project: Project.t(),
          config: Config.t(),
          config_digest: String.t(),
          ci?: boolean(),
          rules: [{module(), Issue.severity()}],
          filters: %{modules: [module()], apps: [atom()]},
          partial?: boolean(),
          capabilities: Compiler.capabilities() | nil,
          modules: [Analysis.result()],
          excluded: [Analysis.result()],
          evidence: Coverage.evidence_map(),
          reachability: %{optional(mfa()) => Reachability.result()},
          beams: [{String.t(), String.t(), String.t() | nil, String.t() | nil}],
          artifacts: [{atom(), BuildRecord.status()}],
          issues: [Issue.t()],
          inventory: [Coverage.entry()],
          ledger: map(),
          baseline: Baseline.t() | nil,
          baseline_path: String.t() | nil,
          baseline_decisions: Baseline.decisions(),
          coverage_violations: [String.t()],
          completion: completion(),
          completion_reasons: [String.t()],
          exit_code: 0 | 1 | 2
        }

  defstruct project: nil,
            config: %Config{},
            config_digest: nil,
            ci?: false,
            rules: [],
            filters: %{modules: [], apps: []},
            partial?: false,
            capabilities: nil,
            modules: [],
            excluded: [],
            evidence: %{},
            reachability: %{},
            beams: [],
            artifacts: [],
            issues: [],
            inventory: [],
            ledger: %{},
            baseline: nil,
            baseline_path: nil,
            baseline_decisions: %{
              applied: false,
              reason: :missing,
              stale_findings: [],
              stale_inventory: [],
              pending_reconciliation: [],
              gate_changed: []
            },
            coverage_violations: [],
            completion: :complete,
            completion_reasons: [],
            exit_code: 0

  @doc "The SpecLint version, from the application spec."
  @spec tool_version() :: String.t()
  def tool_version do
    _ = Application.load(:spec_lint)

    case Application.spec(:spec_lint, :vsn) do
      nil -> "unknown"
      vsn -> List.to_string(vsn)
    end
  end

  @doc """
  Runs SpecLint over `project` with `config`. Returns `{:error, message}`
  for configuration errors found before analysis (exit code 2), including
  a missing ebin directory of an owned application, an ebin missing BEAM
  files its build lists (`SpecLint.Project.check_build_paths/1`), BEAM
  files whose `SpecLint.BuildRecord` names another compiler build or that
  changed after it was written, and an explicitly configured baseline file
  that does not exist (`SpecLint.Config`), and an internal failure after the
  per-module analysis (an exception, throw or exit in the evidence,
  reachability, rule, coverage or baseline stages, which leaves no run to
  report; a failure analysing one module, or a crash of a required
  reachability check, instead makes the run `:incomplete`), otherwise the
  finished run.
  """
  @spec execute(Project.t(), Config.t(), [option()]) :: {:ok, t()} | {:error, String.t()}
  def execute(%Project{} = project, %Config{} = config, opts \\ []) do
    :ok = preload()
    opts = Keyword.put_new_lazy(opts, :today, &Date.utc_today/0)
    filters = %{modules: Keyword.get(opts, :modules, []), apps: Keyword.get(opts, :apps, [])}

    run = %__MODULE__{
      project: project,
      config: config,
      config_digest: Config.digest(config),
      ci?: Keyword.get(opts, :ci, false),
      filters: filters,
      partial?: filters.modules != [] or filters.apps != [],
      baseline_path: config.baseline
    }

    with {:ok, rules} <- Config.enabled_rules(config, opts[:only], opts[:except]),
         :ok <- check_backend(config, rules),
         {:ok, project} <- Project.select_apps(project, filters.apps),
         :ok <- check_build_paths(project),
         {:ok, beams} <- beams(project, filters.modules),
         {:ok, baseline} <- load_baseline(project, config) do
      run = %{run | project: project, rules: rules, baseline: baseline}

      opts
      |> Keyword.get_lazy(:preflight, &Compiler.preflight_once/0)
      |> preflighted(run, beams, opts)
    end
  end

  defp preflighted({:ok, capabilities}, run, beams, opts) do
    with {:ok, artifacts} <- check_artifacts(run.project, capabilities) do
      guarded(fn ->
        analyse(%{run | capabilities: capabilities, artifacts: artifacts}, beams, opts)
      end)
    end
  end

  defp preflighted({:error, reason}, run, _beams, _opts),
    do: {:ok, unsupported_compiler(run, reason)}

  # A failure analysing one module is caught in `analyse_module/3` and makes
  # the run incomplete. An exception, throw or exit in the stages after it
  # (evidence, reachability, rules, coverage, baseline decisions) leaves no
  # run to report: it is an internal failure, returned as an error, so the
  # Mix tasks exit 2 and write no report that could be read as complete
  # (Milestone 5, "resource failures"). An exit is caught too: `exit/1`, or
  # a call that exits (a `GenServer.call/3` timeout, `Task.await/2` on a
  # task that crashed) would otherwise end the Mix task with status 1, the
  # status of new gated findings. The processes the run starts itself are
  # not linked to it (`SpecLint.Isolated`), so their crashes come back as
  # values; exits are trapped while the analysis runs so that a crash of
  # any other linked process (a `Task.async/1` in a stage) reaches this
  # process as a message and its `Task.await/2` as a catchable exit, not as
  # an exit signal that ends the VM.
  defp guarded(analysis) do
    trapping? = Process.flag(:trap_exit, true)

    try do
      {:ok, analysis.()}
    rescue
      error ->
        {:error, "internal failure: " <> Exception.message(error) <> location(__STACKTRACE__)}
    catch
      :throw, value -> {:error, "internal failure: uncaught throw " <> inspect(value)}
      :exit, reason -> {:error, "internal failure: exit " <> inspect(reason)}
    after
      Process.flag(:trap_exit, trapping?)
    end
  end

  defp location([entry | _]), do: " (" <> Exception.format_stacktrace_entry(entry) <> ")"
  defp location([]), do: ""

  # Standard library modules the stages after the analysis use (messages,
  # module names, the reachability processes). See `preload/0`.
  @preloaded [
    Calendar.ISO,
    Date,
    Inspect,
    Inspect.Algebra,
    Inspect.Atom,
    Inspect.BitString,
    Inspect.Float,
    Inspect.Integer,
    Inspect.List,
    Inspect.Map,
    Inspect.Opts,
    Inspect.Tuple,
    MapSet,
    String.Chars,
    String.Chars.Atom,
    String.Chars.Integer,
    String.Chars.List,
    Task,
    Task.Supervised
  ]

  # Loads SpecLint's own modules and `@preloaded` before the analysis. After
  # it this process holds every analysed module's results (a heap of about
  # 3.3 GB on Absinthe), and every module first loaded then, on first call,
  # cost seconds: the lazily loaded coverage, reachability, rule, policy and
  # inspection modules added up to tens of seconds of `execute/3` (Milestone
  # 1 review). Loading is best effort: a module that cannot be loaded here
  # is loaded, or fails, where it is called, as before.
  defp preload do
    _ = Application.load(:spec_lint)
    modules = List.wrap(Application.spec(:spec_lint, :modules)) ++ @preloaded
    _ = :code.ensure_modules_loaded(modules)
    :ok
  end

  defp check_backend(%Config{analysis: :bodies}, _rules),
    do:
      {:error,
       "body analysis (analysis: :bodies) is not available: no qualified compiler build " <>
         "provides the body backend (DESIGN.md section 7)"}

  defp check_backend(_config, rules) do
    case for({rule, _} <- rules, not rule.available?(), do: rule.id()) do
      [] ->
        :ok

      ids ->
        {:error,
         "rule #{Enum.join(ids, ", ")} requires the body analysis backend, which is not " <>
           "available in this build"}
    end
  end

  # Missing build inventory and invalid or misplaced BEAMs are configuration
  # errors (exit 2), never "0 specs" or a smaller project.
  defp check_build_paths(project) do
    case Project.check_build_paths(project) do
      :ok ->
        :ok

      {:error, :missing_module_inventory} ->
        apps =
          Enum.map_join(Project.missing_module_inventories(project), ", ", fn app ->
            "#{app.app} (#{Project.relative(project, app.ebin)})"
          end)

        {:error,
         "incomplete build: no readable module inventory for #{apps}; the compile manifest " <>
           "and application resource file cannot establish whether BEAM files are missing"}

      {:error, :missing_beams} ->
        missing =
          Enum.map_join(Project.missing_modules(project), "; ", fn missing ->
            "#{missing.app} (#{Project.relative(project, missing.ebin)}): " <>
              Enum.map_join(missing.modules, ", ", &inspect/1)
          end)

        {:error,
         "incomplete build: modules the build lists have no BEAM file, so they cannot be " <>
           "analysed: #{missing}; the compile manifest still says the build is up to " <>
           "date, so recompile with mix compile --force"}

      {:error, :module_mismatch} ->
        mismatches =
          Enum.map_join(Project.mismatched_modules(project), "; ", fn mismatch ->
            "#{Project.relative(project, mismatch.path)} contains #{inspect(mismatch.found)}" <>
              " (filename names #{mismatch.expected})"
          end)

        {:error,
         "incomplete build: BEAM filename and embedded module disagree: #{mismatches}; " <>
           "recompile with mix compile --force"}

      {:error, :invalid_beam} ->
        files =
          Enum.map_join(Project.invalid_beams(project), "; ", fn invalid ->
            "#{Project.relative(project, invalid.path)} (#{inspect(invalid.reason)})"
          end)

        {:error,
         "incomplete build: unreadable or invalid BEAM file: #{files}; " <>
           "recompile with mix compile --force"}

      {:error, :missing_build_path} ->
        missing =
          Enum.map_join(Project.missing_build_paths(project), ", ", fn app ->
            "#{app.app} (#{Project.relative(project, app.ebin)})"
          end)

        {:error,
         "missing build directory for #{missing}: the project is not compiled there, " <>
           "so no module can be discovered; compile it first (an existing but empty " <>
           "ebin is a project with 0 specs)"}
    end
  end

  # BEAM files that SpecLint's build record attributes to another compiler
  # build, or that changed after the record was written, would be analysed
  # under the wrong adapter: an incomplete build (exit 2), never a verdict.
  defp check_artifacts(project, capabilities) do
    statuses = BuildRecord.statuses(project, capabilities)

    case for({app, {:mismatch, _} = status} <- statuses, do: {app, status}) do
      [] ->
        {:ok, statuses}

      mismatches ->
        apps =
          Enum.map_join(mismatches, "; ", fn {app, status} ->
            "#{app}: #{BuildRecord.describe(status)}"
          end)

        {:error,
         "incomplete build: BEAM files not produced by the running compiler " <>
           "(#{capabilities.adapter_id}): #{apps}; recompile with mix compile --force " <>
           "(mix spec_lint does this itself)"}
    end
  end

  defp beams(project, []), do: {:ok, Project.beams(project)}

  defp beams(project, modules) do
    beams = Project.beams(project, modules)
    found = MapSet.new(beams, fn {_app, path} -> Path.basename(path, ".beam") end)

    case Enum.reject(modules, &MapSet.member?(found, Atom.to_string(&1))) do
      [] -> {:ok, beams}
      missing -> {:error, "--module #{Enum.map_join(missing, ", ", &inspect/1)} matches nothing"}
    end
  end

  # A missing baseline is "no baseline" only at the default path; an
  # explicit path (--baseline, baseline: in the configuration) must exist.
  defp load_baseline(project, config) do
    path = Path.expand(config.baseline, project.root)

    case Baseline.load(path) do
      {:ok, baseline} ->
        {:ok, baseline}

      :missing when config.baseline_explicit ->
        {:error,
         "baseline file not found: #{Project.relative(project, path)} (given with --baseline " <>
           "or baseline: in the configuration); fix the path, or create the baseline with " <>
           "mix spec_lint.baseline"}

      :missing ->
        {:ok, nil}

      {:error, message} ->
        {:error, message}
    end
  end

  defp unsupported_compiler(run, reason) do
    %{
      run
      | completion: :incomplete,
        completion_reasons: ["unsupported compiler: #{inspect(reason)}"],
        exit_code: if(run.ci?, do: 2, else: 0)
    }
  end

  defp analyse(run, beams, opts) do
    # BEAM hashes are read before the analysis: afterwards this process
    # holds every analysed module, and on a large project (Absinthe: a heap
    # of about 4 GB) the garbage collections that reading hundreds of files
    # triggers cost minutes (Milestone 1 profile).
    identities = Map.new(beams, fn {_app, path} -> {path, Beam.identity(path)} end)
    cache = TypeCache.new()

    {results, failures} =
      try do
        beams
        |> Enum.map(fn {_app, path} -> analyse_module(path, cache, run) end)
        |> Enum.split_with(&match?({:ok, _}, &1))
      after
        TypeCache.delete(cache)
      end

    results = for {:ok, result} <- results, do: result
    failures = for {:error, message} <- failures, do: message

    {excluded, modules} =
      Enum.split_with(results, fn result ->
        Project.excluded?(Project.relative(run.project, result.file), run.config.exclude)
      end)

    evidence = evidence(modules, run.config)

    run = %{
      run
      | modules: modules,
        excluded: excluded,
        evidence: evidence,
        reachability:
          if(sl001_selected?(run), do: Reachability.check(modules, evidence), else: %{}),
        beams: beam_list(run.project, results, identities)
    }

    finish(run, failures, opts)
  end

  defp analyse_module(path, cache, run) do
    {:ok,
     Analysis.module(path,
       cache: cache,
       preflight: {:ok, run.capabilities},
       expand_opaque: run.config.expand_opaque
     )}
  rescue
    error ->
      {:error, "internal failure analysing #{Path.basename(path)}: #{Exception.message(error)}"}
  catch
    :throw, value ->
      {:error,
       "internal failure analysing #{Path.basename(path)}: uncaught throw #{inspect(value)}"}

    :exit, reason ->
      {:error, "internal failure analysing #{Path.basename(path)}: exit #{inspect(reason)}"}
  end

  defp evidence(modules, config) do
    for %{status: :ok} = module <- modules,
        function <- module.functions,
        %{relations: relations} = slice <- function.slices,
        relations != nil,
        into: %{} do
      classification =
        Evidence.classify(relations, require_static_return: config.require_static_return)

      {{function.mfa, slice.index}, classification}
    end
  end

  defp beam_list(project, results, identities) do
    results
    |> Enum.map(fn result ->
      {md5, exck} = Map.get_lazy(identities, result.path, fn -> Beam.identity(result.path) end)
      name = if result.module, do: inspect(result.module), else: Path.basename(result.path)
      {name, Project.relative(project, result.path), md5, exck}
    end)
    |> Enum.sort()
  end

  defp finish(run, failures, opts) do
    inventory = Coverage.inventory(run.modules, run.evidence, run.baseline)
    regressions = Coverage.regressions(inventory, run.baseline)

    issues =
      (run_rules(run) ++ coverage_issues(run, inventory))
      |> Policy.apply_gates(run.config, regressions)

    chunk_reasons = unsupported_chunks(run.modules)
    reachability_reasons = required_reachability_failures(run, issues)
    incomplete? = incomplete?(failures, chunk_reasons, reachability_reasons)

    {issues, decisions} =
      Baseline.decide(issues, run.baseline,
        adapter: run.capabilities.adapter_id,
        complete?: not run.partial? and not incomplete?,
        today: Keyword.get_lazy(opts, :today, &Date.utc_today/0),
        rules: ran_rule_ids(run),
        inventory: inventory
      )

    {issues, coverage_only} = split_coverage_only(run, issues)

    ledger = Coverage.ledger(run.modules, run.excluded, inventory)
    {floor_violations, floor_notes} = floor(run, ledger)
    violations = floor_violations ++ Enum.flat_map(coverage_only, &coverage_violation/1)
    {adapter_reasons, adapter_error?} = adapter_mismatch(run, decisions)

    run = %{
      run
      | issues: Issue.sort(issues),
        inventory: inventory,
        ledger: ledger,
        baseline_decisions: decisions,
        coverage_violations: violations
    }

    blocking? = Enum.any?(run.issues, &Issue.blocking?/1) or violations != []

    errored? = errored?(run, failures, chunk_reasons, reachability_reasons, adapter_error?)

    %{
      run
      | completion: completion(run, incomplete?),
        completion_reasons:
          failures ++ chunk_reasons ++ reachability_reasons ++ adapter_reasons ++ floor_notes,
        exit_code: exit_code(run, errored?, blocking?)
    }
  end

  defp incomplete?(failures, chunks, reachability),
    do: failures != [] or chunks != [] or reachability != []

  defp errored?(run, failures, chunks, reachability, adapter_error?),
    do: failures != [] or adapter_error? or (run.ci? and (chunks != [] or reachability != []))

  # Only a check needed to decide an otherwise eligible SL001 clause gate is
  # required. A disabled rule, a shadowed clause, or another blocked
  # prerequisite must not turn an optional check failure into an incomplete
  # run. Inspect findings before baseline decisions so acknowledgements
  # cannot hide a required failure.
  defp required_reachability_failures(run, issues) do
    for %Issue{rule: "SL001", evidence: :clause_conflict} = issue <- issues,
        issue.data[:reachability_check_required],
        Enum.all?(issue.prerequisites, fn
          {:clause_reachable, _state} -> true
          {_name, state} -> state != :blocked
        end),
        {:error, reason} <- [Map.fetch!(run.reachability, issue.mfa)],
        uniq: true do
      "required reachability check failed for #{Issue.subject(issue)}: #{inspect(reason)}"
    end
  end

  defp split_coverage_only(run, issues) do
    if sl008_selected?(run),
      do: {issues, []},
      else: Enum.split_with(issues, &(&1.rule != "SL008"))
  end

  defp completion(_run, true), do: :incomplete
  defp completion(%{partial?: true}, false), do: :partial
  defp completion(_run, false), do: :complete

  defp exit_code(_run, true, _blocking?), do: 2

  defp exit_code(run, false, blocking?) do
    gating? = run.ci? or run.config.warnings_as_errors
    if gating? and blocking?, do: 1, else: 0
  end

  # The coverage floor is a whole-project property: a partial run does not
  # check it.
  defp floor(run, ledger) do
    compared = ledger["slices"]["compared"]
    floor = run.config.coverage.floor

    cond do
      compared >= floor ->
        {[], []}

      run.partial? ->
        {[], ["coverage floor of #{floor} not checked: partial run"]}

      true ->
        {["#{compared} compared spec slices, below the configured floor of #{floor}"], []}
    end
  end

  defp sl008_selected?(run), do: List.keymember?(run.rules, AnalysisUnavailable, 0)
  defp sl001_selected?(run), do: List.keymember?(run.rules, ReturnConflict, 0)

  # SL008 always runs (coverage), whatever the rule selection.
  defp ran_rule_ids(run),
    do: Enum.uniq(["SL008" | Enum.map(run.rules, fn {rule, _severity} -> rule.id() end)])

  defp coverage_violation(%Issue{} = issue) do
    if Issue.blocking?(issue) do
      slice = if issue.slice, do: " slice #{issue.slice}", else: ""
      regression = if issue.data[:regression], do: ", a coverage regression", else: ""

      [
        "#{Issue.subject(issue)}#{slice} is #{issue.data[:status]} (#{issue.data[:reason]})" <>
          "#{regression}, not acknowledged in the baseline inventory (SL008 is not " <>
          "selected; the coverage policy still applies)"
      ]
    else
      []
    end
  end

  # Modules whose checker chunk was written by another checker version
  # (DESIGN.md 5.1): a preflight failure.
  defp unsupported_chunks(modules) do
    for module <- modules,
        reason <- status_reasons(module),
        AnalysisUnavailable.unsupported_chunk?(reason),
        uniq: true do
      {:checker_chunk, {:checker_version_mismatch, found, expected}} = reason

      "unsupported checker chunk in #{inspect(module.module)}: version #{inspect(found)}, " <>
        "the running checker writes #{inspect(expected)}; recompile the project with the " <>
        "running compiler"
    end
  end

  defp status_reasons(module) do
    module_reason =
      case module.status do
        {:unavailable, reason} -> [reason]
        _ -> []
      end

    module_reason ++ for(%{status: {:unavailable, reason}} <- module.functions, do: reason)
  end

  defp adapter_mismatch(run, %{reason: :adapter_mismatch}) do
    message =
      "baseline #{run.config.baseline} was written by adapter #{run.baseline.adapter}, " <>
        "the current adapter is #{run.capabilities.adapter_id}; review and regenerate it " <>
        "with mix spec_lint.baseline"

    {[message], run.ci?}
  end

  defp adapter_mismatch(_run, _decisions), do: {[], false}

  # Every selected rule except SL008, which coverage_issues/1 runs.
  defp run_rules(run),
    do: rule_issues(run, Enum.reject(run.rules, &match?({AnalysisUnavailable, _}, &1)))

  defp coverage_issues(run, inventory) do
    severity =
      case List.keyfind(run.rules, AnalysisUnavailable, 0) do
        {_rule, severity} -> severity
        nil -> AnalysisUnavailable.default_severity()
      end

    lost = Enum.filter(inventory, &(&1.status == "unanalysed"))

    lost_issues =
      for module <- run.modules,
          issue <-
            AnalysisUnavailable.check_lost(
              %{
                module: module,
                file: Project.relative(run.project, module.file),
                severity: severity
              },
              lost
            ),
          do: issue

    rule_issues(run, [{AnalysisUnavailable, severity}]) ++ lost_issues
  end

  defp rule_issues(run, rules) do
    Enum.flat_map(run.modules, fn module ->
      file = Project.relative(run.project, module.file)
      module_issues(rules, module, file) ++ function_issues(run, rules, module, file)
    end)
  end

  defp module_issues(rules, module, file) do
    for {rule, severity} <- rules,
        Code.ensure_loaded?(rule) and function_exported?(rule, :check_module, 1),
        issue <- rule.check_module(%{module: module, file: file, severity: severity}),
        do: issue
  end

  defp function_issues(run, rules, module, file) do
    for function <- module.functions,
        {rule, severity} <- rules,
        issue <- rule.check_function(function_context(run, module, file, function, severity)),
        do: issue
  end

  defp function_context(run, module, file, function, severity) do
    slices =
      for slice <- function.slices do
        %{slice: slice, evidence: Map.get(run.evidence, {function.mfa, slice.index})}
      end

    %{
      module: module,
      function: function,
      file: file,
      slices: slices,
      severity: severity,
      clause_local_qualification: run.config.clause_local_qualification,
      pattern_diagnostics: Map.get(run.reachability, function.mfa, {:error, :not_checked})
    }
  end
end
