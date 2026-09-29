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

  Prerequisites (`SpecLint.Rule.sl001_prerequisites/1`): no `unsupported`
  loss, no overlap tag, no arrow in the return and no argument translated
  with an `arrow_polarity` loss. For the clause form, containment is part of
  the evidence, and `clause_reachable` approximates "the compiler did not
  flag the clause unreachable", which the checker chunk does not record: it
  is `:blocked` when the clause's domain is covered by the clauses before it
  (`SpecLint.Compare.shadowed/1`, which over-approximates and so never
  misses a clause the compiler reports as redundant) and `:unchecked`
  otherwise. A `no_return()` spec is `SL006`'s case.

  ## Clause-local qualification (experiment, off by default)

  With `clause_local_qualification: true` in the function context
  (`SpecLint.Config`), a clause-level finding replaces the slice-wide
  prerequisites `no_arrow_in_return` and `no_arrow_polarity_argument` by
  `clause_contained_in_lo`: the clause's whole domain tuple is non-empty
  and contained in the tuple of the spec's argument lower bounds `D_lo`
  (`SpecLint.Compare`, `contained_lo?`). The argument, recorded in
  `bench/corpus/clause_local_qualification.md`:

    * `D_lo ⊆ D`, and every translation loss, `arrow_polarity` included
      (its lower bound is `none()`), only shrinks `D_lo`, so a loss can never
      make a clause look contained: every input the clause accepts is in
      the spec domain;
    * `R_k`, the stored clause return, is non-empty and neither top nor
      near-top (the evidence class requires it), and is disjoint from
      `S_hi`, an over-approximation of the spec return by construction: an
      inexact arrow in the return is `fun(arity)` there, still an upper
      bound, so a returned function of that arity is never disjoint from it.

  So any normal return of that clause is outside the spec, whatever arrows
  the rest of the slice contains. A clause contained only in `D_hi` never
  has the class `clause_conflict` (its containment is unknown), and
  `no_unsupported_loss`, `no_overlap` and `clause_reachable` still apply.
  The superseded prerequisites and their states are kept in the issue's
  `data`, so a report shows both readings. The slice-level form keeps the
  slice-wide prerequisites: its applied return `U(D)` comes from applying
  the signature at `D_hi`, not from one contained clause.
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
    clause_local? = Map.get(context, :clause_local_qualification, false)

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
           "clause_conflict (signature backend, #{containment_text(clause_local?)}, " <>
             "#{Rule.translation_string(slice)})"}
        ],
        prerequisites: clause_prerequisites(slice, contributing, clause_local?),
        data: clause_data(slice, clause_local?)
      )
    end
  end

  @superseded [:no_arrow_in_return, :no_arrow_polarity_argument]

  defp clause_prerequisites(slice, contributing, false) do
    Rule.sl001_prerequisites(slice) ++
      [{:clause_contained, :met}, {:clause_reachable, reachable(contributing)}]
  end

  defp clause_prerequisites(slice, contributing, true) do
    kept =
      for {name, _state} = pair <- Rule.sl001_prerequisites(slice),
          name not in @superseded,
          do: pair

    kept ++
      [
        {:clause_contained_in_lo, Rule.state(contributing.contained_lo?)},
        {:clause_reachable, reachable(contributing)}
      ]
  end

  defp clause_data(_slice, false), do: %{}

  defp clause_data(slice, true) do
    superseded =
      for {name, state} <- Rule.sl001_prerequisites(slice), name in @superseded, do: [name, state]

    %{qualification: :clause_local, superseded_prerequisites: superseded}
  end

  defp containment_text(false), do: "clause contained"
  defp containment_text(true), do: "clause contained in the spec lower bound"

  defp clause_text(%{args: args, return: return}), do: Rule.clause_string({args, return})

  defp reachable(%{shadowed?: true}), do: :blocked
  defp reachable(_contributing), do: :unchecked
end
