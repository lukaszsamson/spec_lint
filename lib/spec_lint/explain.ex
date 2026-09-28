defmodule SpecLint.Explain do
  @moduledoc """
  `mix spec_lint --explain Mod.fun/arity` (DESIGN.md section 5.4).

  Prints, for one function: the spec clauses; the translated bounds of
  every argument and of the return with each loss record and its path in
  the type tree; the inferred clauses with their stored precision (static
  or gradual); for each slice the applied clauses and the containment of
  each, the applied return, `extra` and `missing`, the union-level and
  per-clause evidence classes with their reasons; and every finding with
  its prerequisites, the policy outcome and the baseline decision.
  """

  alias SpecLint.{Bound, Compiler, Issue, Policy, Rule, Run}

  @doc """
  Parses `Mod.fun/arity` into an MFA. The module is an Elixir alias
  (`MyApp.Store`) or an Erlang module (`:lists`).
  """
  @spec parse_mfa(String.t()) :: {:ok, mfa()} | {:error, String.t()}
  def parse_mfa(string) do
    with [target, arity] <- split_last(string, "/"),
         {arity, ""} when arity >= 0 <- Integer.parse(arity),
         [module, name] when module != "" and name != "" <- split_last(target, ".") do
      {:ok, {module_atom(module), String.to_atom(name), arity}}
    else
      _ -> {:error, "--explain expects Mod.fun/arity, got: #{inspect(string)}"}
    end
  end

  defp split_last(string, separator) do
    case String.split(string, separator) do
      [_single] -> [string]
      parts -> [parts |> Enum.drop(-1) |> Enum.join(separator), List.last(parts)]
    end
  end

  defp module_atom(":" <> erlang), do: String.to_atom(erlang)
  defp module_atom(elixir), do: Module.concat([elixir])

  @doc """
  Renders the explanation of `mfa` from a run that analysed its module.
  Returns an error when the function is not in the run or out of scope.
  """
  @spec render(Run.t(), mfa()) :: {:ok, iodata()} | {:error, String.t()}
  def render(%Run{} = run, {module, _name, _arity} = mfa) do
    case Enum.find(run.modules, &(&1.module == module)) do
      nil ->
        {:error, "#{inspect(module)} was not analysed (not an owned module, or excluded)"}

      %{status: :ok} = result ->
        case Enum.find(result.functions, &(&1.mfa == mfa)) do
          nil -> not_in_scope(result, mfa)
          function -> {:ok, function_text(run, result, function)}
        end

      %{status: status} ->
        {:error, "#{inspect(module)} could not be analysed: #{inspect(status)}"}
    end
  end

  defp not_in_scope(result, mfa) do
    case Enum.find(result.out_of_scope, &(&1.mfa == mfa)) do
      nil -> {:error, "#{Issue.mfa_string(mfa)} has no spec in #{inspect(result.module)}"}
      %{reason: reason} -> {:error, "#{Issue.mfa_string(mfa)} is out of scope: #{reason}"}
    end
  end

  defp function_text(run, result, function) do
    {_module, name, _arity} = function.mfa
    file = SpecLint.Project.relative(run.project, result.file)
    issues = Enum.filter(run.issues, &(&1.mfa == function.mfa))

    [
      Issue.mfa_string(function.mfa),
      "  (#{file}:#{function.line})\n",
      "status: #{status_string(function.status)}\n\n",
      "Spec clauses:\n",
      for(
        slice <- function.slices,
        do: "  [#{slice.index}] #{Rule.spec_string(name, slice.spec)}\n"
      ),
      "\nTranslated bounds:\n",
      Enum.map(function.slices, &bounds_text/1),
      "\nInferred clauses (stored in the checker chunk):\n",
      inferred_text(function.inferred),
      Enum.map(function.slices, &slice_text(&1, Map.get(run.evidence, {function.mfa, &1.index}))),
      "\nFindings:\n",
      findings_text(issues, run)
    ]
  end

  defp status_string(:compared), do: "compared"
  defp status_string({kind, reason}), do: "#{kind}: #{inspect(reason)}"

  defp bounds_text(%{args: nil} = slice),
    do: "  slice #{slice.index}: not translated (#{status_string(slice.status)})\n"

  defp bounds_text(slice) do
    args =
      slice.args
      |> Enum.with_index(1)
      |> Enum.map(fn {bound, position} -> bound_text("argument #{position}", bound) end)

    ["  slice #{slice.index}:\n", args, bound_text("return", slice.return)]
  end

  defp bound_text(label, %Bound{} = bound) do
    exactness = if Bound.exact?(bound), do: "exact", else: "approximate"

    losses =
      for loss <- bound.losses do
        "        loss #{loss.kind} at #{path_string(loss.path)}\n"
      end

    notes =
      for note <- bound.notes, do: "        note #{note.kind} at #{path_string(note.path)}\n"

    integers =
      if bound.integers, do: "        integers #{inspect(bound.integers)}\n", else: []

    [
      "    #{label} (#{exactness}):\n",
      "        hi: #{Compiler.to_string(bound.hi)}\n",
      if(Bound.exact?(bound), do: [], else: "        lo: #{Compiler.to_string(bound.lo)}\n"),
      losses,
      notes,
      integers
    ]
  end

  @doc """
  Prints a loss path: `argument 1 > tuple element 2 > MyApp.t/0`.
  Positions are 1-based.
  """
  @spec path_string([Bound.segment()]) :: String.t()
  def path_string(path), do: Enum.map_join(path, " > ", &segment/1)

  defp segment({:arg, index}), do: "argument #{index + 1}"
  defp segment(:return), do: "return"
  defp segment({:elem, index}), do: "tuple element #{index + 1}"
  defp segment({:union, index}), do: "union member #{index + 1}"
  defp segment({:fun_arg, index}), do: "fun argument #{index + 1}"
  defp segment(:fun_return), do: "fun return"
  defp segment(:list_elem), do: "list element"
  defp segment(:list_tail), do: "list tail"
  defp segment({:map_value, key}), do: "map value #{inspect(key)}"
  defp segment({:map_key, index}), do: "map key #{index + 1}"
  defp segment({:type, module, name, arity}), do: "#{inspect(module)}.#{name}/#{arity}"
  defp segment(other), do: inspect(other)

  defp inferred_text([]), do: "  none (no inferred signature)\n"

  defp inferred_text(clauses) do
    for {{_args, return} = clause, index} <- Enum.with_index(clauses) do
      precision = if Compiler.gradual?(return), do: "gradual", else: "static"
      "  ##{index} #{Rule.clause_string(clause)}  [#{precision} return]\n"
    end
  end

  defp slice_text(%{relations: nil} = slice, _evidence),
    do: "\nSlice #{slice.index}: #{status_string(slice.status)}\n"

  defp slice_text(slice, evidence) do
    rel = slice.relations

    applied =
      case rel.applied do
        {:ok, indexes} -> Enum.map_join(indexes, ", ", &"##{&1}")
        :badapply -> "none (badapply)"
      end

    [
      "\nSlice #{slice.index} #{Rule.domain_string(slice.args)}:\n",
      "  applied clauses: #{applied}#{if rel.cutoff?, do: " (clause cutoff: dynamic())", else: ""}\n",
      "  applied return (upper bound): #{Compiler.to_string(rel.applied_upper)}\n",
      "  spec return (upper bound): #{Compiler.to_string(rel.spec_return)}\n",
      "  relation: #{rel.return_relation}; established: #{rel.established?}\n",
      "  extra: #{Compiler.to_string(rel.extra)}\n",
      "  missing: #{Compiler.to_string(rel.missing)}\n",
      "  top-only: #{rel.top_only?}; near-top: #{rel.near_top?}; ",
      "input approximate: #{rel.input_approximate?}\n",
      "  overlap: #{overlap(rel)}\n",
      "  contributing clauses:\n",
      Enum.map(rel.contributing, &contributing_text(&1, evidence)),
      evidence_text(evidence)
    ]
  end

  defp overlap(rel) do
    cond do
      rel.overlap? -> "certain with slices #{inspect(rel.overlaps_with)}"
      rel.overlap_unknown? -> "unknown with slices #{inspect(rel.overlaps_unknown_with)}"
      true -> "none"
    end
  end

  defp contributing_text(clause, evidence) do
    per_clause = evidence && Enum.find(evidence.clauses, &(&1.index == clause.index))
    precision = if clause.static_return?, do: "static", else: "gradual"

    class =
      case per_clause do
        nil ->
          ""

        %{class: class, reasons: reasons, extra: extra} ->
          "\n        class #{class}; extra #{Compiler.to_string(extra)}; " <>
            "reasons #{inspect(reasons)}"
      end

    "    ##{clause.index} #{clause.containment}, #{precision} return#{class}\n"
  end

  defp evidence_text(nil), do: []

  defp evidence_text(evidence) do
    components =
      for component <- evidence.components do
        "    #{component.label}#{if component.present_in_contributing?, do: "", else: " (absent)"}" <>
          " #{component.descr_string}\n"
      end

    [
      "  union-level class: #{evidence.union_class}\n",
      components,
      "  reasons: #{inspect(evidence.reasons)}\n",
      "  slice class: #{evidence.class}\n"
    ]
  end

  defp findings_text([], _run), do: "  none\n"

  defp findings_text(issues, run) do
    for issue <- issues do
      [
        "  #{issue.rule} #{issue.name} #{finding_where(issue)}: #{issue.evidence} (#{issue.severity})\n",
        "    #{issue.message}\n",
        "    prerequisites: #{prerequisites_text(issue.prerequisites)}\n",
        "    policy: #{Policy.explain(issue, run.config)}\n",
        "    baseline: #{issue.baseline}; fingerprint #{issue.fingerprint}\n"
      ]
    end
  end

  defp finding_where(issue) do
    [issue.slice && "slice #{issue.slice}", issue.clause && "clause ##{issue.clause}"]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp prerequisites_text([]), do: "none"

  defp prerequisites_text(list),
    do: Enum.map_join(list, ", ", fn {name, state} -> "#{name} #{state}" end)
end
