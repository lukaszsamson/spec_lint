# Phase 0 SL002 experiment runner (DESIGN.md 11, item 1).
#
# Runs SpecLint.Analysis and the SL002 classifier (SpecLint.Evidence) over
# every .beam in the given ebin directories and writes a deterministic JSON
# report plus a one-screen summary on stderr. Every slice is classified
# twice, with require_static_return false (the default, reported as
# `class`) and true (`class_static`), and the per-clause evidence of DESIGN
# 3.1 step 7 is reported for each contributing clause.
#
#     MIX_ENV=test mix run bench/experiment.exs -- \
#       --ebin DIR [--ebin DIR ...] [--code-path DIR ...] \
#       --label NAME --out FILE.json
#
# --code-path directories (and the ebin directories) are prepended to the code
# path so remote types resolve. When the fixture expectations module
# (SpecLint.ExperimentFixtures, compiled in MIX_ENV=test) is available and the
# run covers fixture functions, fixture accuracy and the warn/no-warn outcome
# per fixture are reported too.

defmodule SpecLint.Experiment do
  @moduledoc false

  alias SpecLint.{Analysis, Bound, Compiler, Evidence, TypeCache}

  @fixtures SpecLint.ExperimentFixtures

  def main(argv) do
    argv = Enum.reject(argv, &(&1 == "--"))

    {opts, rest, invalid} =
      OptionParser.parse(argv,
        strict: [ebin: :keep, code_path: :keep, label: :string, out: :string]
      )

    ebins = opts |> Keyword.get_values(:ebin) |> Enum.map(&Path.expand/1)

    if invalid != [] or rest != [] or ebins == [] or opts[:out] == nil do
      IO.puts(:stderr, "usage: --ebin DIR ... [--code-path DIR ...] --label NAME --out FILE.json")
      IO.puts(:stderr, "invalid: #{inspect(invalid ++ rest)}")
      System.halt(2)
    end

    label = opts[:label] || "run"
    code_paths = opts |> Keyword.get_values(:code_path) |> Enum.map(&Path.expand/1)
    Enum.each(code_paths ++ ebins, &Code.prepend_path/1)

    {:ok, capabilities} = Compiler.preflight()
    started = System.monotonic_time(:millisecond)
    cache = TypeCache.new()

    modules =
      ebins
      |> Enum.flat_map(&Path.wildcard(Path.join(&1, "*.beam")))
      |> Enum.sort()
      |> Enum.map(&Analysis.module(&1, cache: cache, preflight: {:ok, capabilities}))

    functions =
      for module <- modules, function <- module.functions do
        function_entry(module, function)
      end
      |> Enum.sort_by(& &1.sort_key)

    runtime_ms = System.monotonic_time(:millisecond) - started
    fixtures = fixture_report(functions)

    report = %{
      label: label,
      ebins: ebins,
      code_paths: code_paths,
      adapter: capabilities.adapter_id,
      otp_release: capabilities.otp_release,
      checker_version: capabilities.checker_version,
      totals: totals(modules, functions, runtime_ms),
      functions: Enum.map(functions, &Map.drop(&1, [:sort_key, :raw])),
      fixtures: fixtures
    }

    out = Path.expand(opts[:out])
    File.mkdir_p!(Path.dirname(out))
    File.write!(out, [encode(report, 0), "\n"])
    summary(report, out)
  end

  ## Per function

  defp function_entry(module, function) do
    {mod, name, arity} = function.mfa
    classifications = Enum.map(function.slices, &classify_slice/1)
    slices = Enum.zip_with(function.slices, classifications, &slice_entry(name, &1, &2))
    class = Evidence.worst(for %{class: class} <- slices, do: class)
    class_static = Evidence.worst(for %{class_static: class} <- slices, do: class)
    mfa = "#{inspect(mod)}.#{name}/#{arity}"

    %{
      sort_key: mfa,
      raw: %{classifications: classifications},
      mfa: mfa,
      file: module.file,
      line: function.line,
      location: location(module.file, function.line),
      status: status_string(function.status),
      specs: Enum.map(function.slices, &spec_string(name, &1.spec)),
      inferred: Enum.map(function.inferred, &clause_string/1),
      class: class,
      class_static: class_static,
      sl002_candidate: Enum.any?(slices, & &1.sl002_candidate),
      sl002_candidate_static: Enum.any?(slices, & &1.sl002_candidate_static),
      clause_conflict_candidate: Enum.any?(slices, & &1.clause_conflict_candidate),
      clause_conflict_candidate_static: Enum.any?(slices, & &1.clause_conflict_candidate_static),
      slices: slices
    }
  end

  defp classify_slice(%{relations: nil}), do: nil

  defp classify_slice(%{relations: relations}) do
    {Evidence.classify(relations), Evidence.classify(relations, require_static_return: true)}
  end

  defp slice_entry(_name, slice, nil) do
    %{
      index: slice.index,
      status: status_string(slice.status),
      sl002_candidate: false,
      sl002_candidate_static: false,
      clause_conflict_candidate: false,
      clause_conflict_candidate_static: false
    }
  end

  defp slice_entry(_name, slice, {classification, static}) do
    rel = slice.relations
    arg_losses = slice.args |> Enum.flat_map(&Bound.loss_kinds/1) |> Enum.uniq() |> Enum.sort()
    return_losses = Bound.loss_kinds(slice.return)
    loss_kinds = Enum.sort(Enum.uniq(arg_losses ++ return_losses))
    arrow_return? = Enum.any?(Compiler.components(slice.return.hi), &(&1.kind == :fun))

    # SL001 prerequisites (DESIGN 4) for a per-clause conflict: no
    # unsupported loss, no overlap tag (certain or unknown), no arrow in the
    # return. Containment of the clause is part of the class itself.
    sl001_ok? =
      not rel.overlap? and not rel.overlap_unknown? and
        :unsupported_construct not in loss_kinds and not arrow_return?

    sl002_ok? =
      not rel.overlap? and not rel.spec_return_empty? and
        :unsupported_construct not in loss_kinds and not arrow_return?

    static_by_index = Map.new(static.clauses, &{&1.index, &1})

    %{
      index: slice.index,
      status: "compared",
      spec_return: Compiler.to_string(slice.return.hi),
      spec_args: Enum.map(slice.args, &Compiler.to_string(&1.hi)),
      arg_loss_kinds: arg_losses,
      return_loss_kinds: return_losses,
      loss_kinds: loss_kinds,
      applied: applied(rel.applied),
      applied_return: Compiler.to_string(rel.applied_upper),
      return_relation: rel.return_relation,
      extra: Compiler.to_string(rel.extra),
      class: classification.class,
      class_static: static.class,
      union_class: classification.union_class,
      union_class_static: static.union_class,
      components: Enum.map(classification.components, &component_entry/1),
      reasons: Enum.map(classification.reasons, &reason_string/1),
      clauses: Enum.map(classification.clauses, &clause_entry(&1, static_by_index[&1.index])),
      input_approximate: rel.input_approximate?,
      top_only: rel.top_only?,
      near_top: rel.near_top?,
      overlap: rel.overlap?,
      overlap_unknown: rel.overlap_unknown?,
      badapply: rel.badapply?,
      cutoff: rel.cutoff?,
      containment:
        Enum.map(rel.contributing, fn clause ->
          %{
            clause: clause.index,
            containment: clause.containment,
            static_return: clause.static_return?
          }
        end),
      # SL002 prerequisites (DESIGN 4): structured_possible, no unsupported
      # loss, no overlap tag, no arrow in the return. A no_return() spec is
      # SL006's case, not SL002's.
      sl002_candidate: classification.class == :structured_possible and sl002_ok?,
      sl002_candidate_static: static.class == :structured_possible and sl002_ok?,
      clause_conflict_candidate: classification.class == :clause_conflict and sl001_ok?,
      clause_conflict_candidate_static: static.class == :clause_conflict and sl001_ok?
    }
  end

  defp clause_entry(clause, static) do
    %{
      clause: clause.index,
      containment: clause.containment,
      static_return: clause.static_return?,
      class: clause.class,
      class_static: static.class,
      extra: Compiler.to_string(clause.extra),
      components: Enum.map(clause.components, &component_entry/1),
      reasons: Enum.map(clause.reasons, &reason_string/1)
    }
  end

  defp component_entry(component) do
    %{
      descr: component.descr_string,
      kind: component.kind,
      label: component.label,
      present_in_contributing: component.present_in_contributing?,
      tag_in_spec: component.tag_in_spec?,
      subtraction_payload: component.subtraction_payload?,
      payload_gradual: component.payload_gradual?,
      detail: component.detail
    }
  end

  defp applied({:ok, indexes}), do: indexes
  defp applied(:badapply), do: "badapply"

  defp location(nil, _line), do: nil
  defp location(file, nil), do: file
  defp location(file, line), do: "#{file}:#{line}"

  defp spec_string(name, spec) do
    name |> Code.Typespec.spec_to_quoted(spec) |> Macro.to_string()
  rescue
    _ -> inspect(spec)
  end

  defp clause_string({args, return}) do
    "(#{Enum.map_join(args, ", ", &Compiler.to_string/1)}) -> #{Compiler.to_string(return)}"
  end

  defp status_string(:compared), do: "compared"
  defp status_string({kind, reason}), do: "#{kind}:#{reason_key(reason)}"

  defp reason_string({key, value}), do: "#{key}=#{inspect(value, charlists: :as_lists)}"
  defp reason_string(key), do: Atom.to_string(key)

  # A short, stable key for a reason term: its leading atoms, two levels deep.
  defp reason_key(reason, depth \\ 2)
  defp reason_key(reason, _depth) when is_atom(reason), do: Atom.to_string(reason)

  defp reason_key(reason, depth) when is_tuple(reason) and tuple_size(reason) > 0 do
    case {elem(reason, 0), tuple_size(reason)} do
      {head, 2} when is_atom(head) and depth > 1 ->
        inner = elem(reason, 1)

        if is_atom(inner) or
             (is_tuple(inner) and tuple_size(inner) > 0 and is_atom(elem(inner, 0))),
           do: "#{head}:#{reason_key(inner, depth - 1)}",
           else: Atom.to_string(head)

      {head, _} when is_atom(head) ->
        Atom.to_string(head)

      _ ->
        "other"
    end
  end

  defp reason_key(_reason, _depth), do: "other"

  ## Totals

  defp totals(modules, functions, runtime_ms) do
    slices = Enum.flat_map(functions, & &1.slices)
    compared = Enum.filter(slices, &(&1.status == "compared"))

    %{
      runtime_ms: runtime_ms,
      modules: length(modules),
      modules_by_status: frequencies(modules, &module_status/1),
      out_of_scope_by_reason:
        modules |> Enum.flat_map(& &1.out_of_scope) |> frequencies(&Atom.to_string(&1.reason)),
      functions: length(functions),
      functions_by_status: frequencies(functions, &status_prefix(&1.status)),
      slices: length(slices),
      slices_compared: length(compared),
      unsupported_by_reason:
        slices
        |> Enum.filter(&String.starts_with?(&1.status, "unsupported:"))
        |> frequencies(&strip_prefix(&1.status)),
      unavailable_by_reason:
        slices
        |> Enum.filter(&String.starts_with?(&1.status, "unavailable:"))
        |> frequencies(&strip_prefix(&1.status)),
      slice_classes: frequencies(compared, &Atom.to_string(&1.class)),
      slice_classes_static: frequencies(compared, &Atom.to_string(&1.class_static)),
      union_classes: frequencies(compared, &Atom.to_string(&1.union_class)),
      clause_classes:
        compared |> Enum.flat_map(& &1.clauses) |> frequencies(&Atom.to_string(&1.class)),
      clause_classes_static:
        compared
        |> Enum.flat_map(& &1.clauses)
        |> frequencies(&Atom.to_string(&1.class_static)),
      function_classes: frequencies(functions, &Atom.to_string(&1.class)),
      function_classes_static: frequencies(functions, &Atom.to_string(&1.class_static)),
      slices_exact: Enum.count(compared, &(&1.loss_kinds == [])),
      slices_approximate: Enum.count(compared, &(&1.loss_kinds != [])),
      loss_kinds: compared |> Enum.flat_map(& &1.loss_kinds) |> frequencies(&Atom.to_string/1),
      component_labels:
        compared
        |> Enum.flat_map(& &1.components)
        |> frequencies(&"#{&1.label}#{if &1.present_in_contributing, do: "", else: "_absent"}"),
      top_only_slices: Enum.count(compared, & &1.top_only),
      near_top_slices: Enum.count(compared, & &1.near_top),
      badapply_slices: Enum.count(compared, & &1.badapply),
      overlap_slices: Enum.count(compared, & &1.overlap),
      overlap_unknown_slices: Enum.count(compared, & &1.overlap_unknown),
      clause_conflict_candidate_functions: Enum.count(functions, & &1.clause_conflict_candidate),
      clause_conflict_candidate_functions_static:
        Enum.count(functions, & &1.clause_conflict_candidate_static),
      sl002_candidate_slices: Enum.count(compared, & &1.sl002_candidate),
      sl002_candidate_functions: Enum.count(functions, & &1.sl002_candidate),
      sl002_candidate_functions_static: Enum.count(functions, & &1.sl002_candidate_static),
      sl002_candidate_slices_tag_in_spec:
        Enum.count(compared, fn slice ->
          slice.sl002_candidate and Enum.any?(slice.components, & &1.tag_in_spec)
        end)
    }
  end

  defp module_status(%{status: :ok}), do: "ok"
  defp module_status(%{status: {kind, reason}}), do: "#{kind}:#{reason_key(reason)}"

  defp status_prefix(status), do: status |> String.split(":", parts: 2) |> hd()
  defp strip_prefix(status), do: status |> String.split(":", parts: 2) |> List.last()

  defp frequencies(enum, fun), do: enum |> Enum.map(fun) |> Enum.frequencies()

  ## Fixtures

  defp fixture_report(functions) do
    if Code.ensure_loaded?(@fixtures) and function_exported?(@fixtures, :expected, 0) do
      by_mfa = Map.new(functions, &{&1.mfa, &1})

      entries =
        for {{mod, name, arity}, expected} <- @fixtures.expected(),
            function = by_mfa["#{inspect(mod)}.#{name}/#{arity}"],
            function != nil do
          warn? = function.sl002_candidate or function.clause_conflict_candidate

          warn_static? =
            function.sl002_candidate_static or function.clause_conflict_candidate_static

          expected_static = Map.get(expected, :static_class, expected.class)

          %{
            mfa: function.mfa,
            expected_class: expected.class,
            class: function.class,
            class_ok: expected.class == function.class,
            expected_class_static: expected_static,
            class_static: function.class_static,
            class_static_ok: expected_static == function.class_static,
            omission: expected.omission?,
            warn: warn?,
            outcome: outcome(expected.omission?, warn?),
            warn_static: warn_static?,
            outcome_static: outcome(expected.omission?, warn_static?),
            note: expected.note
          }
        end
        |> Enum.sort_by(& &1.mfa)

      if entries == [] do
        nil
      else
        %{
          total: length(entries),
          class_ok: Enum.count(entries, & &1.class_ok),
          class_static_ok: Enum.count(entries, & &1.class_static_ok),
          outcomes: frequencies(entries, & &1.outcome),
          outcomes_static: frequencies(entries, & &1.outcome_static),
          entries: entries
        }
      end
    end
  end

  # Warn means an SL002 candidate or a gated SL001 per-clause conflict, under
  # the setting of require_static_return being reported.
  defp outcome(true, true), do: "detected"
  defp outcome(true, false), do: "suppressed"
  defp outcome(false, true), do: "false_positive"
  defp outcome(false, false), do: "true_negative"

  ## Summary

  defp summary(report, out) do
    t = report.totals

    lines =
      [
        "spec_lint experiment: #{report.label} (#{report.adapter}, OTP #{report.otp_release})",
        "  runtime:      #{t.runtime_ms} ms",
        "  modules:      #{t.modules} #{fmt(t.modules_by_status)}",
        "  out of scope: #{fmt(t.out_of_scope_by_reason)}",
        "  functions:    #{t.functions} #{fmt(t.functions_by_status)}",
        "  slices:       #{t.slices} (compared #{t.slices_compared}, exact #{t.slices_exact}, " <>
          "approximate #{t.slices_approximate})",
        "  unsupported:  #{fmt(t.unsupported_by_reason)}",
        "  unavailable:  #{fmt(t.unavailable_by_reason)}",
        "  slice classes:    #{fmt(t.slice_classes)}",
        "  slice classes (require_static_return): #{fmt(t.slice_classes_static)}",
        "  union-level slice classes: #{fmt(t.union_classes)}",
        "  clause classes:   #{fmt(t.clause_classes)}",
        "  clause classes (require_static_return): #{fmt(t.clause_classes_static)}",
        "  function classes: #{fmt(t.function_classes)}",
        "  function classes (require_static_return): #{fmt(t.function_classes_static)}",
        "  losses:       #{fmt(t.loss_kinds)}",
        "  components:   #{fmt(t.component_labels)}",
        "  top-only #{t.top_only_slices}, near-top #{t.near_top_slices}, " <>
          "badapply #{t.badapply_slices}, overlap #{t.overlap_slices}, " <>
          "overlap unknown #{t.overlap_unknown_slices}",
        "  SL001 clause-conflict candidates: #{t.clause_conflict_candidate_functions} " <>
          "functions (require_static_return: " <>
          "#{t.clause_conflict_candidate_functions_static})",
        "  SL002 candidates: #{t.sl002_candidate_slices} slices, " <>
          "#{t.sl002_candidate_functions} functions " <>
          "(require_static_return: #{t.sl002_candidate_functions_static}) " <>
          "(#{t.sl002_candidate_slices_tag_in_spec} slices with a tag already in the spec)"
      ] ++
        candidate_lines(report.functions) ++
        conflict_lines(report.functions) ++ fixture_lines(report.fixtures) ++ ["  -> #{out}"]

    IO.puts(:stderr, Enum.join(lines, "\n"))
  end

  defp candidate_lines(functions) do
    candidates = Enum.filter(functions, & &1.sl002_candidate)

    shown =
      for function <- Enum.take(candidates, 12) do
        extra =
          function.slices
          |> Enum.filter(&Map.get(&1, :sl002_candidate))
          |> Enum.map_join(" | ", & &1.extra)

        "    #{function.mfa}: #{extra |> String.replace(~r/\s+/, " ") |> String.slice(0, 70)}"
      end

    more = if length(candidates) > 12, do: ["    ... #{length(candidates) - 12} more"], else: []
    shown ++ more
  end

  defp conflict_lines(functions) do
    candidates = Enum.filter(functions, & &1.clause_conflict_candidate)

    shown =
      for function <- Enum.take(candidates, 12) do
        extra =
          function.slices
          |> Enum.flat_map(&Map.get(&1, :clauses, []))
          |> Enum.filter(&(&1.class == :clause_conflict))
          |> Enum.map_join(" | ", &"##{&1.clause} #{&1.extra}")

        "    conflict #{function.mfa}: " <>
          (extra |> String.replace(~r/\s+/, " ") |> String.slice(0, 70))
      end

    more = if length(candidates) > 12, do: ["    ... #{length(candidates) - 12} more"], else: []
    shown ++ more
  end

  defp fixture_lines(nil), do: []

  defp fixture_lines(fixtures) do
    wrong =
      for entry <- fixtures.entries, not (entry.class_ok and entry.class_static_ok) do
        "    MISMATCH #{entry.mfa}: expected #{entry.expected_class} / " <>
          "#{entry.expected_class_static}, got #{entry.class} / #{entry.class_static}"
      end

    [
      "  fixtures: class #{fixtures.class_ok}/#{fixtures.total} as expected " <>
        "(require_static_return: #{fixtures.class_static_ok}/#{fixtures.total}); " <>
        "outcomes #{fmt(fixtures.outcomes)}; " <>
        "require_static_return outcomes #{fmt(fixtures.outcomes_static)}"
      | wrong
    ]
  end

  defp fmt(map) when map_size(map) == 0, do: "-"

  defp fmt(map) do
    map
    |> Enum.sort_by(fn {key, count} -> {-count, key} end)
    |> Enum.map_join(", ", fn {key, count} -> "#{key} #{count}" end)
  end

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

SpecLint.Experiment.main(System.argv())
