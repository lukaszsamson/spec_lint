defmodule SpecLint.Rules.ReturnConflict do
  @moduledoc """
  `SL001 return_conflict` (DESIGN.md sections 3 and 4).

  Two forms, both with evidence that any normal return would be outside
  the spec:

    * slice level (`:conflict`): the applied return `U(D)` is non-empty and
      disjoint from `S_hi`;
    * clause level (`:clause_conflict`, DESIGN 3.1 step 7): a contributing
      clause whose domain is contained in the spec domain has a stored
      return disjoint from `S_hi`. Reported once per such clause, and only
      when the slice-level form did not fire.

  Prerequisites: no `unsupported` loss, no overlap tag, no arrow in the
  return. For the clause form, containment is part of the evidence and
  reachability of the clause is `:unchecked` (the checker chunk does not
  record it). A `no_return()` spec is `SL006`'s case.
  """

  @behaviour SpecLint.Rule

  alias SpecLint.{Compiler, Rule}

  @impl true
  @spec id() :: String.t()
  def id, do: "SL001"

  @impl true
  @spec name() :: :return_conflict
  def name, do: :return_conflict

  @impl true
  @spec default_severity() :: :warning
  def default_severity, do: :warning

  @impl true
  @spec summary() :: String.t()
  def summary, do: "any normal return in a spec slice would be outside the spec"

  @impl true
  @spec available?() :: true
  def available?, do: true

  @doc """
  Whether a compared slice's applied return is non-empty and disjoint from
  the spec return (the slice-level form).
  """
  @spec slice_conflict?(SpecLint.Analysis.slice()) :: boolean()
  def slice_conflict?(%{relations: nil}), do: false

  def slice_conflict?(%{relations: relations}) do
    relations.applied != :badapply and relations.return_relation == :disjoint and
      not relations.spec_return_empty?
  end

  @impl true
  @spec check_function(Rule.function_context()) :: [SpecLint.Issue.t()]
  def check_function(context) do
    Enum.flat_map(context.slices, fn
      %{evidence: nil} ->
        []

      %{slice: slice, evidence: evidence} ->
        if slice_conflict?(slice),
          do: [slice_issue(context, slice)],
          else: clause_issues(context, slice, evidence)
    end)
  end

  defp slice_issue(context, slice) do
    name = Rule.function_name(context)
    rel = slice.relations

    Rule.function_issue(__MODULE__, context,
      slice: slice.index,
      evidence: :conflict,
      message: "any normal return would be outside the spec",
      details: [
        {"spec", Rule.spec_string(name, slice.spec)},
        {"inferred return", Compiler.to_string(rel.applied_upper)},
        {"slice", Rule.domain_string(slice.args)},
        {"evidence", "conflict (signature backend, #{Rule.translation_string(slice)})"}
      ],
      prerequisites: Rule.sl001_prerequisites(slice)
    )
  end

  defp clause_issues(context, slice, evidence) do
    name = Rule.function_name(context)

    for %{class: :clause_conflict} = clause <- evidence.clauses do
      contributing = Enum.find(slice.relations.contributing, &(&1.index == clause.index))

      Rule.function_issue(__MODULE__, context,
        slice: slice.index,
        clause: clause.index,
        inferred: [clause.index],
        evidence: :clause_conflict,
        message: "the clause matching this domain returns only values outside the spec",
        details: [
          {"spec", Rule.spec_string(name, slice.spec)},
          {"inferred clause", "##{clause.index} " <> clause_text(contributing)},
          {"slice", Rule.domain_string(slice.args)},
          {"evidence",
           "clause_conflict (signature backend, clause contained, " <>
             "#{Rule.translation_string(slice)})"}
        ],
        prerequisites:
          Rule.sl001_prerequisites(slice) ++
            [{:clause_contained, :met}, {:clause_reachable, :unchecked}]
      )
    end
  end

  defp clause_text(%{args: args, return: return}), do: Rule.clause_string({args, return})
end
