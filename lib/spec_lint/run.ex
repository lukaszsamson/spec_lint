defmodule SpecLint.Run do
  @moduledoc """
  One SpecLint run over a project (DESIGN.md section 5): preflight, BEAM
  discovery, analysis, evidence, rules, coverage, policy and baseline
  decisions, ending in an exit code. It prints nothing and never exits;
  the Mix task maps `exit_code` to the process status at its boundary.

  Exit codes: `0` accepted; `1` new gated findings or a coverage violation
  (only in CI mode or with `warnings_as_errors`); `2` incomplete run
  (internal failure analysing a module; unsupported compiler or checker
  chunk in CI), unsupported backend, configuration error.

  Completion is `:complete`, `:partial` (a `--module` or `--app` filter
  was given; stale entries are never declared and the coverage floor is
  not checked) or `:incomplete` (an internal failure, or a checker chunk
  written by another checker version, which fails preflight: exit 2 in CI).

  Coverage (`SL008`) is always evaluated. When rule selection (`--rules`,
  `--except`, `rules: [analysis_unavailable: :off]`) leaves SL008 out, its
  findings are not reported, but the ones that would block become coverage
  violations, so selecting rules never bypasses the coverage policy. Stale
  baseline findings are declared only for the rules that ran.
  """

  alias SpecLint.{
    Analysis,
    Baseline,
    Compiler,
    Config,
    Coverage,
    Evidence,
    Issue,
    Policy,
    Project,
    TypeCache
  }

  alias SpecLint.Rules.AnalysisUnavailable

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
          beams: [{String.t(), String.t(), String.t() | nil}],
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
            beams: [],
            issues: [],
            inventory: [],
            ledger: %{},
            baseline: nil,
            baseline_path: nil,
            baseline_decisions: %{
              applied: false,
              reason: :missing,
              stale_findings: [],
              stale_inventory: []
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
  for configuration errors found before analysis (exit code 2), otherwise
  the finished run.
  """
  @spec execute(Project.t(), Config.t(), [option()]) :: {:ok, t()} | {:error, String.t()}
  def execute(%Project{} = project, %Config{} = config, opts \\ []) do
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
         {:ok, beams} <- beams(project, filters.modules),
         {:ok, baseline} <- load_baseline(project, config) do
      run = %{run | project: project, rules: rules, baseline: baseline}

      case Keyword.get_lazy(opts, :preflight, &Compiler.preflight_once/0) do
        {:ok, capabilities} ->
          {:ok, analyse(%{run | capabilities: capabilities}, beams, opts)}

        {:error, reason} ->
          {:ok, unsupported_compiler(run, reason)}
      end
    end
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

  defp beams(project, []), do: {:ok, Project.beams(project)}

  defp beams(project, modules) do
    beams = Project.beams(project, modules)
    found = MapSet.new(beams, fn {_app, path} -> Path.basename(path, ".beam") end)

    case Enum.reject(modules, &MapSet.member?(found, Atom.to_string(&1))) do
      [] -> {:ok, beams}
      missing -> {:error, "--module #{Enum.map_join(missing, ", ", &inspect/1)} matches nothing"}
    end
  end

  defp load_baseline(project, config) do
    case Baseline.load(Path.expand(config.baseline, project.root)) do
      {:ok, baseline} -> {:ok, baseline}
      :missing -> {:ok, nil}
      {:error, message} -> {:error, message}
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
        beams: beam_list(run.project, results)
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

  defp beam_list(project, results) do
    results
    |> Enum.map(fn result ->
      md5 = beam_md5(result.path)
      name = if result.module, do: inspect(result.module), else: Path.basename(result.path)
      {name, Project.relative(project, result.path), md5}
    end)
    |> Enum.sort()
  end

  defp beam_md5(path) do
    case :beam_lib.md5(String.to_charlist(path)) do
      {:ok, {_module, md5}} -> Base.encode16(md5, case: :lower)
      {:error, :beam_lib, _reason} -> nil
    end
  end

  defp finish(run, failures, opts) do
    inventory = Coverage.inventory(run.modules, run.evidence)
    regressions = Coverage.regressions(inventory, run.baseline)

    issues =
      (run_rules(run) ++ coverage_issues(run))
      |> Policy.apply_gates(run.config, regressions)

    chunk_reasons = unsupported_chunks(run.modules)
    incomplete? = failures != [] or chunk_reasons != []

    {issues, decisions} =
      Baseline.decide(issues, run.baseline,
        adapter: run.capabilities.adapter_id,
        complete?: not run.partial? and not incomplete?,
        today: Keyword.get_lazy(opts, :today, &Date.utc_today/0),
        rules: ran_rule_ids(run),
        inventory: inventory
      )

    {issues, coverage_only} =
      if sl008_selected?(run),
        do: {issues, []},
        else: Enum.split_with(issues, &(&1.rule != "SL008"))

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

    completion =
      cond do
        incomplete? -> :incomplete
        run.partial? -> :partial
        true -> :complete
      end

    gating? = run.ci? or run.config.warnings_as_errors
    blocking? = Enum.any?(run.issues, &Issue.blocking?/1) or violations != []

    exit_code =
      cond do
        failures != [] or adapter_error? -> 2
        chunk_reasons != [] and run.ci? -> 2
        gating? and blocking? -> 1
        true -> 0
      end

    %{
      run
      | completion: completion,
        completion_reasons: failures ++ chunk_reasons ++ adapter_reasons ++ floor_notes,
        exit_code: exit_code
    }
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

  defp coverage_issues(run) do
    severity =
      case List.keyfind(run.rules, AnalysisUnavailable, 0) do
        {_rule, severity} -> severity
        nil -> AnalysisUnavailable.default_severity()
      end

    rule_issues(run, [{AnalysisUnavailable, severity}])
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

    %{module: module, function: function, file: file, slices: slices, severity: severity}
  end
end
