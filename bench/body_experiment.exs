# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2021 The Elixir Team
# SPDX-FileCopyrightText: 2012 Plataformatec
#
# Contains adapted grouping helpers from Elixir c24c235 Module.Types.
# Modified: compiler operations are routed through SpecLint.Compiler;
# the surrounding body experiment and metrics are SpecLint code.
# Source attribution and license: THIRD_PARTY_NOTICES.md and LICENSE.

# Body-backend experiment (DESIGN.md section 7, STATUS.md next step 1).
#
# Re-runs the compiler's type checker over each spec'd function under the
# argument domain of one spec slice at a time, through the
# `Module.Types.warnings/7` hook of the `ls-typespec-tightening` branch
# (commit b88a257a3), and classifies the body-derived signature with the
# existing SpecLint.Compare and SpecLint.Evidence, exactly as the product
# classifies the stored signature.
#
# The hook is not in any released compiler. This script must run under a
# build of the pinned revision (c24c235) with only that patch applied, not
# under `mix run`:
#
#     $ELIXIR_BODY/bin/elixir -pa _build/test/lib/spec_lint/ebin \
#       bench/body_experiment.exs -- \
#       --ebin DIR [--ebin DIR ...] [--code-path DIR ...] \
#       [--module Mod ...] [--prefix Mod ...] [--sample N --seed S] \
#       --label NAME --out FILE.json
#
# Module selection: --module names modules exactly, --prefix selects every
# module whose name starts with the prefix, and every module holding one of
# the nine known omissions (@omissions) is always selected. --sample N adds N
# other modules drawn at random (seed --seed, default 20260928) from those
# with at least one compared slice. With no --module, --prefix or --sample,
# every module is selected.
#
# Per module, three signatures are classified for every compared slice:
#
#   * signature  - the stored signature from the ExCk chunk (the product);
#   * default    - warnings/7 with every domain `:default` (arguments
#                  dynamic()). The checker runs in :dynamic mode here, so
#                  remote calls are resolved, unlike the :infer mode that
#                  produced the stored signature. This column separates that
#                  effect from the spec domain;
#   * body       - warnings/7 with the target function's domain set to
#                  {:dynamic, [dynamic(D_hi_i)]} of this slice and every other
#                  function (helpers) :default. One call per slice, so each
#                  slice gets a fresh checker context (a new context() per
#                  call); only the remote-export cache is shared.
#
# The body-derived clauses of the target (`local_sigs`, compacted as the
# compiler does before writing the ExCk chunk) take the place of the
# inferred clauses in SpecLint.Compare.slice/3 (application at D_hi,
# containment, overlap with the translated sibling slices) and the result is
# classified with SpecLint.Evidence.classify/1. `gate` counts qualified
# SL001 conflicts, `candidate` counts SL002 `structured_possible` candidates,
# and `reported` counts SL001/SL002 findings. The historical `warn` field
# remains their qualified conflict/candidate union for comparison with old
# reports; it is not a CI gate count.
#
# The checker warnings of each body run are diffed against the default run
# (by formatted message and location); the extra ones are reported per
# slice. A fourth mode, `body_guarded`, is `body` with the redundancy guard:
# a slice whose body run reports a clause of the target redundant does not
# warn, because the checker still types that clause's body into the
# signature. Wall time is measured per warnings/7 call (`body_us`,
# `default_run_us`, `totals.cost`).

Code.require_file("body_metrics.exs", __DIR__)

defmodule SpecLint.BodyExperiment do
  @moduledoc false

  alias SpecLint.{Analysis, BodyMetrics, Bound, Compare, Compiler, Evidence, TypeCache}

  @fixtures SpecLint.ExperimentFixtures

  # The nine confirmed omissions (EXPERIMENTS.md "Real omissions found") and
  # their reproducers (bench/corpus/omissions/README.md).
  @omissions [
    {"Decimal.compare/2", "SpecLint.OmissionFixtures.Cases.compare/2"},
    {"Decimal.cmp/2", "SpecLint.OmissionFixtures.Cases.cmp/2"},
    {"Plug.Conn.Query.decode/4", "SpecLint.OmissionFixtures.Cases.decode/2"},
    {"Plug.Conn.merge_private/2", "SpecLint.OmissionFixtures.Cases.merge_private/2"},
    {"Ecto.Changeset.apply_action/2", "SpecLint.OmissionFixtures.Cases.apply_action/2"},
    {"Ecto.Query.Builder.Join.escape/3", "SpecLint.OmissionFixtures.Cases.join_escape/3"},
    {"Ecto.Query.Builder.quoted_type/2", "SpecLint.OmissionFixtures.Cases.quoted_type/2"},
    {"Ecto.Repo.Assoc.query/4", "SpecLint.OmissionFixtures.Cases.assoc_query/4"},
    {"Ecto.Repo.Preloader.query/7", "SpecLint.OmissionFixtures.Cases.preloader_query/7"}
  ]

  @modes [:signature, :default, :body, :body_guarded]

  @spec main([String.t()]) :: term()
  def main(argv) do
    argv = Enum.reject(argv, &(&1 == "--"))

    {opts, rest, invalid} =
      OptionParser.parse(argv,
        strict: [
          ebin: :keep,
          code_path: :keep,
          module: :keep,
          prefix: :keep,
          sample: :integer,
          seed: :integer,
          label: :string,
          out: :string
        ]
      )

    ebins = opts |> Keyword.get_values(:ebin) |> Enum.map(&Path.expand/1)

    if invalid != [] or rest != [] or ebins == [] or opts[:out] == nil do
      IO.puts(:stderr, "usage: --ebin DIR ... [--module M] [--sample N] --label L --out FILE")
      IO.puts(:stderr, "invalid: #{inspect(invalid ++ rest)}")
      System.halt(2)
    end

    code_paths = opts |> Keyword.get_values(:code_path) |> Enum.map(&Path.expand/1)
    # Ebins first on the code path: remote calls and remote types resolve to
    # the modules under analysis.
    Enum.each(code_paths, &Code.prepend_path/1)
    Enum.each(ebins, &Code.prepend_path/1)

    {:ok, capabilities} = Compiler.preflight()

    unless capabilities.body_hook do
      IO.puts(:stderr, "Module.Types.warnings/7 is not exported: run under the patched build")
      System.halt(2)
    end

    cache = TypeCache.new()

    analysed =
      ebins
      |> Enum.flat_map(&Path.wildcard(Path.join(&1, "*.beam")))
      |> Enum.sort()
      |> Enum.map(&Analysis.module(&1, cache: cache, preflight: {:ok, capabilities}))
      |> Enum.filter(&(&1.status == :ok))

    {selected, sampled} = select(analysed, opts)
    {:ok, checker} = Module.ParallelChecker.start_link()

    modules =
      try do
        Enum.map(selected, &module_entry(&1, checker, &1.module in sampled))
        |> Enum.map(fn m ->
          %{m | functions: Enum.map(m.functions, &%{&1 | sampled: m.sampled})}
        end)
      after
        Module.ParallelChecker.stop(checker)
      end

    functions = Enum.flat_map(modules, & &1.functions)

    report = %{
      label: opts[:label] || "run",
      adapter: capabilities.adapter_id,
      body_hook: capabilities.body_hook,
      otp_release: capabilities.otp_release,
      checker_version: capabilities.checker_version,
      ebins: ebins,
      sample: %{
        size: opts[:sample] || 0,
        seed: seed(opts),
        modules: Enum.map(sampled, &inspect/1)
      },
      modules:
        Enum.map(modules, fn m ->
          %{
            module: inspect(m.module),
            sampled: m.sampled,
            default_run_us: m.default_us,
            default_warnings: m.default_warnings,
            error: m.error
          }
        end),
      totals: totals(modules, functions),
      omissions: omission_report(functions),
      fixtures: fixture_report(functions, opts[:label]),
      changed: changed(functions),
      functions: functions
    }

    out = Path.expand(opts[:out])
    File.mkdir_p!(Path.dirname(out))
    File.write!(out, [encode(report, 0), "\n"])
    summary(report, out)
  end

  ## Selection

  defp seed(opts), do: opts[:seed] || 20_260_928

  defp select(analysed, opts) do
    names = opts |> Keyword.get_values(:module) |> MapSet.new()
    prefixes = Keyword.get_values(opts, :prefix)

    omission_modules =
      MapSet.new(for {mfa, fixture} <- @omissions, m <- [mfa, fixture], do: mod(m))

    explicit? = MapSet.size(names) > 0 or prefixes != [] or opts[:sample] != nil

    chosen =
      Enum.filter(analysed, fn a ->
        name = inspect(a.module)

        not explicit? or MapSet.member?(names, name) or
          Enum.any?(prefixes, &String.starts_with?(name, &1)) or
          MapSet.member?(omission_modules, name)
      end)

    chosen_set = MapSet.new(chosen, & &1.module)

    candidates =
      analysed
      |> Enum.reject(&MapSet.member?(chosen_set, &1.module))
      |> Enum.filter(fn a -> Enum.any?(a.functions, &compared_slice?/1) end)
      |> Enum.sort_by(&inspect(&1.module))

    sampled =
      case opts[:sample] do
        nil ->
          []

        n ->
          :rand.seed(:exsss, {seed(opts), 0, 0})
          candidates |> Enum.shuffle() |> Enum.take(n)
      end

    selected = Enum.sort_by(chosen ++ sampled, &inspect(&1.module))
    {selected, Enum.map(sampled, & &1.module) |> Enum.sort()}
  end

  defp compared_slice?(function), do: Enum.any?(function.slices, &(&1.status == :compared))

  defp mod(mfa) do
    [name | _] = String.split(mfa, "/")
    name |> String.split(".") |> Enum.drop(-1) |> Enum.join(".")
  end

  ## Per module

  defp module_entry(analysis, checker, sampled?) do
    base = %{module: analysis.module, sampled: sampled?, functions: [], error: nil}

    case debug_info(analysis.path, analysis.module) do
      {:ok, info} ->
        {default_us, default} = timed_run(analysis.module, info, checker, fn _ -> :default end)
        default_entry(base, default_us, default, analysis, info, checker)

      {:error, reason} ->
        Map.merge(base, %{default_us: 0, default_warnings: 0, error: inspect(reason)})
    end
  end

  defp default_entry(base, default_us, {:ok, warnings, sigs}, analysis, info, checker) do
    functions =
      for function <- analysis.functions, compared_slice?(function) do
        function_entry(analysis, function, info, checker, warnings, sigs)
      end

    Map.merge(base, %{
      default_us: default_us,
      default_warnings: length(warnings),
      functions: functions
    })
  end

  defp default_entry(base, default_us, {:error, message}, _analysis, _info, _checker),
    do: Map.merge(base, %{default_us: default_us, default_warnings: 0, error: message})

  defp debug_info(path, module) do
    with {:ok, binary} <- File.read(path),
         {:ok, {^module, [debug_info: {:debug_info_v1, backend, data}]}} <-
           :beam_lib.chunks(binary, [:debug_info]),
         {:ok, %{definitions: defs, attributes: attrs, file: file}} <-
           backend.debug_info(:elixir_v1, module, data, []) do
      {:ok, %{defs: defs, attrs: Keyword.take(attrs, [:__protocol__, :__impl__]), file: file}}
    else
      other -> {:error, other}
    end
  end

  defp timed_run(module, info, checker, domains) do
    :timer.tc(fn ->
      try do
        {warnings, sigs} =
          Module.Types.warnings(module, info.file, info.attrs, info.defs, :all, checker, domains)

        {:ok, warnings, sigs}
      rescue
        error -> {:error, Exception.message(error) |> String.slice(0, 300)}
      end
    end)
  end

  ## Per function

  defp function_entry(analysis, function, info, checker, default_warnings, default_sigs) do
    {mod, name, arity} = function.mfa
    fun_arity = {name, arity}
    mfa = "#{inspect(mod)}.#{name}/#{arity}"
    default_keys = MapSet.new(default_warnings, &warning_key/1)
    default_clauses = local_clauses(default_sigs, fun_arity)

    context = %{
      analysis: analysis,
      function: function,
      info: info,
      checker: checker,
      fun_arity: fun_arity,
      default_keys: default_keys,
      default_clauses: default_clauses
    }

    slices =
      for slice <- function.slices, slice.status == :compared do
        slice_entry(slice, context)
      end

    classes = Map.new(@modes, fn m -> {m, worst_of(slices, m)} end)

    %{
      mfa: mfa,
      line: function.line,
      sampled: false,
      slices: slices,
      class: classes,
      available: Map.new(@modes, fn m -> {m, Enum.all?(slices, &is_map(&1[m]))} end),
      gate: Map.new(@modes, fn m -> {m, BodyMetrics.flag(slices, m, :gate)} end),
      candidate: Map.new(@modes, fn m -> {m, BodyMetrics.flag(slices, m, :candidate)} end),
      reported: Map.new(@modes, fn m -> {m, BodyMetrics.flag(slices, m, :reported)} end),
      warn: Map.new(@modes, fn m -> {m, BodyMetrics.flag(slices, m, :warn)} end),
      omission: omission_name(mfa)
    }
  end

  defp sibling(%{status: :compared} = other),
    do: {other.index, %{args: other.args, return: other.return}}

  defp sibling(other), do: {other.index, {:unsupported, nil}}

  defp slice_entry(slice, context) do
    %{
      analysis: analysis,
      function: function,
      info: info,
      checker: checker,
      fun_arity: fun_arity,
      default_keys: default_keys,
      default_clauses: default_clauses
    } = context

    others = for other <- function.slices, other.index != slice.index, do: sibling(other)

    translated = %{args: slice.args, return: slice.return}
    domain = {:dynamic, Enum.map(slice.args, &Compiler.dynamic(&1.hi))}
    domains = fn fa -> if fa == fun_arity, do: domain, else: :default end
    {us, result} = timed_run(analysis.module, info, checker, domains)

    {body, extra_warnings, redundant, error} =
      case result do
        {:ok, warnings, sigs} ->
          extra = Enum.reject(warnings, &MapSet.member?(default_keys, warning_key(&1)))

          {local_clauses(sigs, fun_arity),
           extra |> Enum.map(&format_warning/1) |> Enum.uniq() |> Enum.sort(),
           Enum.count(extra, &redundant_in?(&1, function.mfa)), nil}

        {:error, message} ->
          {nil, [], 0, message}
      end

    body = classify(translated, body, others, slice)

    %{
      index: slice.index,
      spec_args: Enum.map(slice.args, &Compiler.to_string(&1.hi)),
      spec_return: Compiler.to_string(slice.return.hi),
      loss_kinds: loss_kinds(slice),
      body_us: us,
      body_error: error,
      extra_warnings: extra_warnings,
      redundant_in_target: redundant,
      signature: mode_entry(slice.relations, slice, function.inferred),
      default: classify(translated, default_clauses, others, slice),
      body: body,
      body_guarded: guarded(body, redundant)
    }
  end

  # The redundancy guard: a body run that proves a clause of the target
  # redundant under the spec domain (a {:redundant, ...} warning located in
  # the target that the default run does not emit) still types that
  # clause's body into the target's signature, so its evidence is blocked.
  defp guarded(nil, _redundant), do: nil
  defp guarded(entry, 0), do: entry

  defp guarded(entry, _redundant) do
    %{
      entry
      | gate: false,
        candidate: false,
        reported: false,
        warn: false,
        guard_blocked: entry.warn
    }
  end

  defp redundant_in?({_module, warning, {_file, _meta, mfa}}, mfa)
       when is_tuple(warning) and elem(warning, 0) == :redundant,
       do: true

  defp redundant_in?(_warning, _mfa), do: false

  # The local signature as the compiler would store it: warnings/7 returns
  # the raw local_sigs, while Module.Types.infer/7 compacts clauses with
  # group_clauses_by_return/1 before writing the ExCk chunk. Without the
  # compaction a many-clause function (Plug.Conn.Status.code/1, 70 clauses)
  # exceeds the 16-clause application cutoff and becomes top-only.
  defp local_clauses(sigs, fun_arity) do
    case Map.get(sigs, fun_arity) do
      {_kind, {:infer, _domain, [_ | _] = clauses}, _mapping} -> group_by_return(clauses)
      _ -> nil
    end
  end

  # A copy of the private Module.Types.group_clauses_by_return/1 (c24c235).
  defp group_by_return([{[_ | _], _} | _] = clauses) do
    Enum.reduce(clauses, [], fn {args, return}, acc -> group_clause(acc, args, return) end)
  end

  defp group_by_return(clauses), do: clauses

  defp group_clause([{existing_args, return} | tail], args, return) do
    case union_args(existing_args, args, [], false) do
      nil -> [{existing_args, return} | group_clause(tail, args, return)]
      new_args -> [{new_args, return} | tail]
    end
  end

  defp group_clause([head | tail], args, return), do: [head | group_clause(tail, args, return)]
  defp group_clause([], args, return), do: [{args, return}]

  defp union_args([arg | existing], [arg | args], acc, changed?),
    do: union_args(existing, args, [arg | acc], changed?)

  defp union_args([existing_arg | existing], [arg | args], acc, false),
    do: union_args(existing, args, [Compiler.union(existing_arg, arg) | acc], true)

  defp union_args([_ | _], [_ | _], _acc, true), do: nil
  defp union_args([], [], acc, _changed?), do: Enum.reverse(acc)

  defp classify(_translated, nil, _others, _slice), do: nil

  defp classify(translated, clauses, others, slice) do
    relations = Compare.slice(translated, clauses, others)
    mode_entry(relations, slice, clauses)
  end

  defp mode_entry(nil, _slice, _clauses), do: nil

  defp mode_entry(relations, slice, clauses) do
    classification = Evidence.classify(relations)
    flags = mode_flags(relations, slice, classification)

    %{
      class: classification.class,
      union_class: classification.union_class,
      reasons: Enum.map(classification.reasons, &reason_string/1),
      clause_conflict_candidate: flags.clause_conflict_candidate,
      sl002_candidate: flags.candidate,
      gate: flags.gate,
      candidate: flags.candidate,
      reported: flags.reported,
      warn: flags.warn,
      guard_blocked: false,
      top_only: relations.top_only?,
      near_top: relations.near_top?,
      # `none` only says the extra over S_hi is empty; the obligation is
      # established (DESIGN.md section 3) only when U(D) is within S_lo,
      # which needs an exact return.
      established: relations.established?,
      return_exact: Bound.exact?(slice.return),
      applied: applied(relations.applied),
      applied_return: Compiler.to_string(relations.applied_upper),
      extra: Compiler.to_string(relations.extra),
      clauses: Enum.map(clauses, &clause_string/1),
      clause_evidence:
        Enum.map(classification.clauses, fn c ->
          %{
            clause: c.index,
            containment: c.containment,
            class: c.class,
            extra: Compiler.to_string(c.extra),
            reasons: Enum.map(c.reasons, &reason_string/1)
          }
        end)
    }
  end

  # The historical warning metric is kept separate from the actual gate and
  # reported finding metrics. All successful runs retain their old `warn`.
  defp mode_flags(relations, slice, classification) do
    clause_conflict? = reachable_conflict?(classification)
    slice_conflict? = slice_conflict?(relations)
    sl001_ok? = eligible_sl001?(relations, slice)
    conflict? = clause_conflict? and sl001_ok?

    candidate? =
      classification.class == :structured_possible and eligible_sl002?(relations, slice)

    %{
      clause_conflict_candidate: conflict?,
      gate: (clause_conflict? or slice_conflict?) and sl001_ok?,
      candidate: candidate?,
      reported: reported?(relations, classification, slice_conflict?),
      warn: conflict? or candidate?
    }
  end

  defp plain?(relations, slice) do
    arrow_return? = Enum.any?(Compiler.components(slice.return.hi), &(&1.kind == :fun))

    not relations.overlap? and :unsupported_construct not in loss_kinds(slice) and
      not arrow_return?
  end

  defp eligible_sl001?(relations, slice) do
    arg_losses = slice.args |> Enum.flat_map(&Bound.loss_kinds/1) |> Enum.uniq()

    plain?(relations, slice) and not relations.overlap_unknown? and
      :arrow_polarity not in arg_losses
  end

  defp eligible_sl002?(relations, slice),
    do: plain?(relations, slice) and not relations.spec_return_empty?

  defp slice_conflict?(relations),
    do:
      relations.applied != :badapply and relations.return_relation == :disjoint and
        not relations.spec_return_empty?

  defp reported?(relations, classification, slice_conflict?) do
    sl002? =
      classification.class in [
        :structured_possible,
        :possible_gradual,
        :possible_domain_escape,
        :possible_input_approximate,
        :whole_kind_possible
      ] and not relations.spec_return_empty? and not slice_conflict?

    Enum.any?(classification.clauses, &(&1.class == :clause_conflict)) or slice_conflict? or
      sl002?
  end

  defp reachable_conflict?(classification) do
    Enum.any?(classification.clauses, fn c ->
      c.class == :clause_conflict and :possibly_shadowed not in c.reasons
    end)
  end

  defp worst_of(slices, mode) do
    if Enum.any?(slices, &is_nil(&1[mode])) do
      nil
    else
      slices |> Enum.map(& &1[mode].class) |> Evidence.worst()
    end
  end

  defp loss_kinds(slice) do
    (Enum.flat_map(slice.args, &Bound.loss_kinds/1) ++ Bound.loss_kinds(slice.return))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp omission_name(mfa) do
    Enum.find_value(@omissions, fn {original, fixture} ->
      cond do
        mfa == original -> original
        mfa == fixture -> original
        true -> nil
      end
    end)
  end

  ## Warnings

  # Warning entries are {module, warning, {file, meta, mfa}} (Module.Types.Helpers).
  defp warning_key({module, warning, location}) do
    {format_message(module, warning), location_string(location)}
  end

  defp format_warning({module, warning, location}) do
    "#{location_string(location)}: #{format_message(module, warning)}"
  end

  defp format_message(module, warning) do
    %{message: message} = module.format_diagnostic(warning)
    message |> IO.iodata_to_binary() |> String.split("\n") |> hd()
  rescue
    _ -> inspect(warning, limit: 5)
  end

  defp location_string({file, meta, mfa}) do
    line = if is_list(meta), do: Keyword.get(meta, :line), else: nil

    where =
      if match?({_, _, _}, mfa),
        do: Exception.format_mfa(elem(mfa, 0), elem(mfa, 1), elem(mfa, 2)),
        else: inspect(mfa)

    "#{Path.basename(to_string(file))}:#{line || "?"} (#{where})"
  end

  defp location_string(other), do: inspect(other)

  ## Reports

  defp totals(modules, functions) do
    slices = Enum.flat_map(functions, & &1.slices)
    body_us = for s <- slices, do: s.body_us
    default_us = for m <- modules, do: m.default_us

    %{
      modules: length(modules),
      modules_sampled: Enum.count(modules, & &1.sampled),
      module_errors: Enum.count(modules, &(&1.error != nil)),
      functions: length(functions),
      slices: length(slices),
      body_errors: Enum.count(slices, &(&1.body_error != nil)),
      body_unavailable: Enum.count(slices, &(&1.body == nil)),
      function_classes:
        Map.new(@modes, fn m -> {m, frequencies(functions, &"#{&1.class[m]}")} end),
      slice_classes:
        Map.new(@modes, fn m ->
          {m, frequencies(slices, &"#{if &1[m], do: &1[m].class}")}
        end),
      top_only_slices:
        Map.new(@modes, fn m -> {m, Enum.count(slices, &(&1[m] && &1[m].top_only))} end),
      unavailable_functions:
        Map.new(@modes, fn m -> {m, Enum.count(functions, &(not &1.available[m]))} end),
      gate_functions: Map.new(@modes, fn m -> {m, Enum.count(functions, & &1.gate[m])} end),
      candidate_functions:
        Map.new(@modes, fn m -> {m, Enum.count(functions, & &1.candidate[m])} end),
      reported_functions:
        Map.new(@modes, fn m -> {m, Enum.count(functions, & &1.reported[m])} end),
      warn_functions: Map.new(@modes, fn m -> {m, Enum.count(functions, & &1.warn[m])} end),
      extra_warning_slices: Enum.count(slices, &(&1.extra_warnings != [])),
      extra_warnings: slices |> Enum.map(&length(&1.extra_warnings)) |> Enum.sum(),
      cost: %{
        body_calls: length(body_us),
        body_total_ms: div(Enum.sum(body_us), 1000),
        body_median_us: percentile(body_us, 50),
        body_p90_us: percentile(body_us, 90),
        body_max_us: Enum.max(body_us, fn -> 0 end),
        default_calls: length(default_us),
        default_total_ms: div(Enum.sum(default_us), 1000)
      }
    }
  end

  defp percentile([], _p), do: 0

  defp percentile(values, p) do
    sorted = Enum.sort(values)
    Enum.at(sorted, min(length(sorted) - 1, div(length(sorted) * p, 100)))
  end

  defp omission_report(functions) do
    for f <- functions, f.omission != nil do
      %{
        mfa: f.mfa,
        omission: f.omission,
        class: f.class,
        available: f.available,
        gate: f.gate,
        candidate: f.candidate,
        reported: f.reported,
        warn: f.warn,
        detected_gate: f.gate.body,
        detected_candidate: f.candidate.body,
        detected_reported: f.reported.body,
        detected: f.warn.body,
        detected_guarded: f.warn.body_guarded,
        slices:
          Enum.map(f.slices, fn s ->
            %{
              index: s.index,
              signature: s.signature.class,
              default: s.default && s.default.class,
              body: s.body && s.body.class,
              body_top_only: s.body && s.body.top_only,
              body_reasons: s.body && s.body.reasons,
              body_extra: s.body && s.body.extra
            }
          end)
      }
    end
  end

  defp fixture_report(functions, label) do
    if label == "fixtures" and Code.ensure_loaded?(@fixtures) and
         function_exported?(@fixtures, :expected, 0) do
      by_mfa = Map.new(functions, &{&1.mfa, &1})

      entries =
        for {{mod, name, arity}, expected} <- @fixtures.expected() do
          mfa = "#{inspect(mod)}.#{name}/#{arity}"
          fixture_entry(mfa, expected, by_mfa[mfa])
        end
        |> Enum.sort_by(& &1.mfa)

      %{
        total: length(entries),
        gate_outcomes:
          Map.new(@modes, fn m -> {m, frequencies(entries, & &1.gate_outcome[m])} end),
        candidate_outcomes:
          Map.new(@modes, fn m -> {m, frequencies(entries, & &1.candidate_outcome[m])} end),
        reported_outcomes:
          Map.new(@modes, fn m -> {m, frequencies(entries, & &1.reported_outcome[m])} end),
        outcomes: Map.new(@modes, fn m -> {m, frequencies(entries, & &1.outcome[m])} end),
        entries: entries
      }
    end
  end

  defp fixture_entry(mfa, expected, nil) do
    unavailable = Map.new(@modes, &{&1, "unavailable"})

    %{
      mfa: mfa,
      omission: expected.omission?,
      expected_class: expected.class,
      class: Map.new(@modes, &{&1, nil}),
      available: Map.new(@modes, &{&1, false}),
      gate_outcome: unavailable,
      candidate_outcome: unavailable,
      reported_outcome: unavailable,
      outcome: unavailable
    }
  end

  defp fixture_entry(_mfa, expected, function) do
    %{
      mfa: function.mfa,
      omission: expected.omission?,
      expected_class: expected.class,
      class: function.class,
      available: function.available,
      gate_outcome:
        Map.new(@modes, fn m ->
          {m, BodyMetrics.outcome(expected.omission?, function.gate[m])}
        end),
      candidate_outcome:
        Map.new(@modes, fn m ->
          {m, BodyMetrics.outcome(expected.omission?, function.candidate[m])}
        end),
      reported_outcome:
        Map.new(@modes, fn m ->
          {m, BodyMetrics.outcome(expected.omission?, function.reported[m])}
        end),
      outcome:
        Map.new(@modes, fn m ->
          {m, BodyMetrics.outcome(expected.omission?, function.warn[m])}
        end)
    }
  end

  # Functions whose class or warn/no-warn outcome differs between the
  # signature and the body run.
  defp changed(functions) do
    for f <- functions,
        f.class.signature != f.class.body or f.warn.signature != f.warn.body or
          f.gate.signature != f.gate.body or f.reported.signature != f.reported.body do
      %{
        mfa: f.mfa,
        signature: f.class.signature,
        default: f.class.default,
        body: f.class.body,
        gate_signature: f.gate.signature,
        gate_body: f.gate.body,
        candidate_signature: f.candidate.signature,
        candidate_body: f.candidate.body,
        reported_signature: f.reported.signature,
        reported_body: f.reported.body,
        warn_signature: f.warn.signature,
        warn_body: f.warn.body,
        warn_body_guarded: f.warn.body_guarded
      }
    end
  end

  defp summary(report, out) do
    t = report.totals

    lines =
      [
        "body experiment: #{report.label} (#{report.adapter}, hook #{report.body_hook})",
        "  modules #{t.modules} (sampled #{t.modules_sampled}, errors #{t.module_errors}), " <>
          "functions #{t.functions}, slices #{t.slices}, body errors #{t.body_errors}",
        "  cost: #{t.cost.body_calls} body calls, total #{t.cost.body_total_ms} ms, " <>
          "median #{t.cost.body_median_us} us, p90 #{t.cost.body_p90_us} us, " <>
          "max #{t.cost.body_max_us} us; default runs #{t.cost.default_total_ms} ms",
        "  extra warnings: #{t.extra_warnings} on #{t.extra_warning_slices} slices"
      ] ++
        for m <- @modes do
          "  #{m}: functions #{fmt(t.function_classes[m])}; unavailable " <>
            "#{t.unavailable_functions[m]}, gate #{t.gate_functions[m]}, " <>
            "candidate #{t.candidate_functions[m]}, reported #{t.reported_functions[m]}, " <>
            "legacy warn #{t.warn_functions[m]}; " <>
            "top-only slices #{t.top_only_slices[m]}"
        end ++
        for o <- report.omissions do
          "  omission #{o.mfa}: #{o.class.signature} -> default #{o.class.default} -> " <>
            "body #{o.class.body} (gate #{o.detected_gate}, candidate #{o.detected_candidate}, " <>
            "reported #{o.detected_reported}, legacy detected #{o.detected})"
        end ++
        for c <- report.changed do
          "  changed #{c.mfa}: #{c.signature} -> #{c.body} " <>
            "(gate #{c.gate_signature} -> #{c.gate_body}, " <>
            "candidate #{c.candidate_signature} -> #{c.candidate_body}, " <>
            "reported #{c.reported_signature} -> #{c.reported_body}, " <>
            "legacy warn #{c.warn_signature} -> #{c.warn_body}, guarded #{c.warn_body_guarded})"
        end ++ fixture_lines(report.fixtures) ++ ["  -> #{out}"]

    IO.puts(:stderr, Enum.join(lines, "\n"))
  end

  defp fixture_lines(nil), do: []

  defp fixture_lines(fixtures) do
    for m <- @modes do
      "  fixtures (#{fixtures.total}) #{m}: gate #{fmt(fixtures.gate_outcomes[m])}; " <>
        "candidate #{fmt(fixtures.candidate_outcomes[m])}; " <>
        "reported #{fmt(fixtures.reported_outcomes[m])}; " <>
        "legacy #{fmt(fixtures.outcomes[m])}"
    end
  end

  defp frequencies(enum, fun), do: enum |> Enum.map(fun) |> Enum.frequencies()

  defp fmt(map) when map_size(map) == 0, do: "-"

  defp fmt(map) do
    map
    |> Enum.sort_by(fn {key, count} -> {-count, key} end)
    |> Enum.map_join(", ", fn {key, count} -> "#{key} #{count}" end)
  end

  defp applied({:ok, indexes}), do: indexes
  defp applied(:badapply), do: "badapply"

  defp clause_string({args, return}) do
    "(#{Enum.map_join(args, ", ", &Compiler.to_string/1)}) -> #{Compiler.to_string(return)}"
  end

  defp reason_string({key, value}), do: "#{key}=#{inspect(value, charlists: :as_lists)}"
  defp reason_string(key), do: Atom.to_string(key)

  ## Deterministic JSON (sorted object keys, two-space indentation)

  defp encode(map, _indent) when is_map(map) and map_size(map) == 0, do: "{}"

  defp encode(map, indent) when is_map(map) do
    pad = String.duplicate("  ", indent + 1)

    pairs =
      map
      |> Enum.map(fn {key, value} -> {to_string(key), value} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, value} ->
        [pad, JSON.encode!(key), ": ", encode(value, indent + 1)]
      end)
      |> Enum.intersperse(",\n")

    ["{\n", pairs, "\n", String.duplicate("  ", indent), "}"]
  end

  defp encode([], _indent), do: "[]"

  defp encode(list, indent) when is_list(list) do
    if Enum.all?(list, &(is_binary(&1) or is_number(&1) or is_atom(&1))) and length(list) <= 8 do
      ["[", list |> Enum.map(&encode(&1, indent)) |> Enum.intersperse(", "), "]"]
    else
      pad = String.duplicate("  ", indent + 1)
      items = list |> Enum.map(&[pad, encode(&1, indent + 1)]) |> Enum.intersperse(",\n")
      ["[\n", items, "\n", String.duplicate("  ", indent), "]"]
    end
  end

  defp encode(nil, _indent), do: "null"
  defp encode(true, _indent), do: "true"
  defp encode(false, _indent), do: "false"
  defp encode(value, _indent) when is_atom(value), do: JSON.encode!(Atom.to_string(value))
  defp encode(value, _indent) when is_binary(value) or is_number(value), do: JSON.encode!(value)
end

SpecLint.BodyExperiment.main(System.argv())
