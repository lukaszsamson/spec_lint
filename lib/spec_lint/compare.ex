defmodule SpecLint.Compare do
  @moduledoc """
  Raw per-slice relations between a translated spec and an inferred
  signature (DESIGN.md sections 3, 3.1 and 5.3).

  These are relations, not verdicts: rules decide what to report. For a
  slice with argument bounds `D_lo`/`D_hi` and return bounds `S_lo`/`S_hi`,
  the inferred signature is applied at `D_hi` with the checker's own
  application rule (`SpecLint.Compiler.apply_infer/2`), giving `U(D)`, the
  gradual upper bound of the applied return. Translation bounds and gradual
  bounds are never merged.

  When no inferred clause applies (`applied: :badapply`), the applied
  return is taken as `none()` for `extra`, `missing` and `return_relation`,
  which then describe nothing about the function's returns; consumers check
  `applied` first. `established?` is `false` in that case: a rejected domain
  never establishes the obligation.

  `top_only?` means `term() ⊆ U(D)`. `near_top?` (DESIGN.md 3.1 step 8)
  means the applied return is not top-only but is treated like it: see
  `near_top?/2`.

  Overlap between overloads (`overlap?`, `overlap_unknown?`) is decided on
  whole argument tuples. Two slices certainly overlap when their lower
  bounds share a value (`D_lo ⊆ D`), and certainly do not when their upper
  bounds are disjoint or when some argument position has disjoint integer
  intervals (`SpecLint.Bound.integer_intervals/1`, for literal integers,
  ranges and refinements the lattice erases to `integer()`). Otherwise
  overlap is unknown: the tag is `overlap_unknown?`, never `overlap?`, so a
  translation loss cannot create a false overlap.

  An unsupported sibling slice still counts for overlap: it was never
  interpreted, so the slices it may share inputs with get
  `overlap_unknown?` with its index. The one exception is a sibling whose
  argument domain is shown disjoint from the slice from what could be
  translated of its arguments, taken as upper bounds
  (`SpecLint.Translate.argument_bounds/2`, an untranslatable position being
  `term()`): the same disjointness tests as above, on `hi` and on integer
  intervals. A sibling without translatable arguments is unknown.

  All functions are pure.
  """

  alias SpecLint.{Bound, Compiler}

  @typedoc "Set relation of a left type to a right type."
  @type relation :: :equal | :subset | :superset | :disjoint | :overlapping | :empty

  @typedoc """
  Containment of one contributing inferred clause's domain in the spec slice
  domain (DESIGN.md 3.1 step 3).
  """
  @type containment :: :contained | :domain_escape | :containment_unknown

  @typedoc """
  An inferred clause that the application rule selected for a slice.
  `shadowed?` means the clause may be unreachable: its domain tuple is
  contained in the union of the domain tuples of the clauses before it
  (see `shadowed/1`).
  """
  @type contributing :: %{
          index: non_neg_integer(),
          args: [Compiler.descr()],
          return: Compiler.descr(),
          static_return?: boolean(),
          containment: containment(),
          shadowed?: boolean()
        }

  @typedoc "Per-position relation of the spec argument to the inferred domain."
  @type domain_relation :: %{spec: relation(), inferred: Compiler.descr()}

  @typedoc "Relations for one spec slice."
  @type relations :: %{
          applied: {:ok, [non_neg_integer()]} | :badapply,
          applied_return: Compiler.descr(),
          applied_upper: Compiler.descr(),
          spec_return: Compiler.descr(),
          cutoff?: boolean(),
          top_only?: boolean(),
          near_top?: boolean(),
          extra: Compiler.descr(),
          missing: Compiler.descr(),
          return_relation: relation(),
          established?: boolean(),
          spec_return_empty?: boolean(),
          return_exact?: boolean(),
          domain_relation: [relation()],
          inferred_domain: [Compiler.descr()],
          domain_overlap?: boolean(),
          badapply?: boolean(),
          overlap?: boolean(),
          overlaps_with: [non_neg_integer()],
          overlap_unknown?: boolean(),
          overlaps_unknown_with: [non_neg_integer()],
          contributing: [contributing()],
          input_approximate?: boolean()
        }

  @typedoc "Result of the all-`dynamic()` argument probe."
  @type probe :: %{
          applied: {:ok, [non_neg_integer()]} | :badapply,
          return: Compiler.descr(),
          relation: relation() | :badapply
        }

  @typedoc """
  A translated slice, or the reason it could not be translated, optionally
  with the upper bounds of its arguments (`SpecLint.Translate.argument_bounds/2`).
  Without them the unsupported slice's domain is unknown.
  """
  @type slice_input ::
          {:ok, SpecLint.Translate.slice()}
          | {:unsupported, term()}
          | {:unsupported, term(), [Bound.t()]}

  @typedoc """
  A sibling slice for the overlap tag: translated, or unsupported with the
  upper bounds of its arguments when known (`nil` when not).
  """
  @type sibling ::
          {non_neg_integer(), SpecLint.Translate.slice()}
          | {non_neg_integer(), {:unsupported, [Bound.t()] | nil}}

  @doc """
  Compares every slice of one function. Unsupported slices are passed
  through as `{:unsupported, reason}`; they still count as siblings for the
  overlap tag of the translated slices (see the moduledoc): a supported
  slice is never tagged free of overlap while an unsupported sibling may
  share its inputs.
  """
  @spec function([slice_input()], [Compiler.clause()], arity()) :: %{
          slices: [{:ok, relations()} | {:unsupported, term()}],
          dynamic_probe: probe()
        }
  def function(slices, clauses, arity) do
    translated = for {{:ok, slice}, index} <- Enum.with_index(slices), do: {index, slice}
    siblings = slices |> Enum.with_index() |> Enum.map(&sibling/1)

    results =
      slices
      |> Enum.with_index()
      |> Enum.map(fn
        {{:ok, slice}, index} ->
          others = for {other, s} <- siblings, other != index, do: {other, s}
          {:ok, slice(slice, clauses, others)}

        {{:unsupported, reason}, _index} ->
          {:unsupported, reason}

        {{:unsupported, reason, _bounds}, _index} ->
          {:unsupported, reason}
      end)

    spec_returns = for {_index, slice} <- translated, do: slice.return.hi
    %{slices: results, dynamic_probe: dynamic_probe(clauses, arity, spec_returns)}
  end

  defp sibling({{:ok, slice}, index}), do: {index, slice}
  defp sibling({{:unsupported, _reason}, index}), do: {index, {:unsupported, nil}}
  defp sibling({{:unsupported, _reason, bounds}, index}), do: {index, {:unsupported, bounds}}

  @doc """
  Relations for one translated slice against the inferred `clauses`.
  `others` are the function's other slices with their indexes, used for
  the overlap tag: translated slices, or unsupported ones as
  `{:unsupported, argument_bounds | nil}` (see the moduledoc).
  """
  @spec slice(SpecLint.Translate.slice(), [Compiler.clause()], [sibling()]) :: relations()
  def slice(%{args: args, return: return}, clauses, others \\ []) do
    d_hi = Enum.map(args, & &1.hi)
    d_lo = Enum.map(args, & &1.lo)
    s_hi = return.hi
    input_approximate? = Enum.any?(args, &(not Bound.exact?(&1)))

    {applied, applied_return, used} =
      case Compiler.apply_infer(clauses, d_hi) do
        {used, type} -> {{:ok, Enum.sort(used)}, type, Enum.sort(used)}
        :error -> {:badapply, Compiler.none(), []}
      end

    upper = Compiler.upper_bound(applied_return)
    inferred_domain = inferred_domain(clauses, length(args))
    spec_domain = Compiler.tuple(d_hi)
    overlaps = for {index, other} <- others, do: {index, sibling_overlap(args, other)}
    overlaps_with = for {index, :yes} <- overlaps, do: index
    overlaps_unknown_with = for {index, :unknown} <- overlaps, do: index
    top_only? = applied != :badapply and Compiler.subtype?(Compiler.term(), upper)

    %{
      applied: applied,
      applied_return: applied_return,
      applied_upper: upper,
      spec_return: s_hi,
      cutoff?: length(used) > Compiler.max_clauses(),
      top_only?: top_only?,
      near_top?: applied != :badapply and not top_only? and near_top?(upper, s_hi),
      extra: Compiler.difference(upper, s_hi),
      missing: Compiler.difference(s_hi, upper),
      return_relation: relation(upper, s_hi),
      established?: applied != :badapply and Compiler.subtype?(upper, return.lo),
      spec_return_empty?: Compiler.empty?(s_hi),
      return_exact?: Bound.exact?(return),
      domain_relation: Enum.zip_with(d_hi, inferred_domain, &relation/2),
      inferred_domain: inferred_domain,
      domain_overlap?: domain_overlap?(spec_domain, clauses),
      badapply?: applied == :badapply and Enum.all?(d_hi, &(not Compiler.empty?(&1))),
      overlap?: overlaps_with != [],
      overlaps_with: overlaps_with,
      overlap_unknown?: overlaps_unknown_with != [],
      overlaps_unknown_with: overlaps_unknown_with,
      contributing: contributing(clauses, used, spec_domain, input_approximate?, d_lo),
      input_approximate?: input_approximate?
    }
  end

  @doc """
  Whether a return upper bound `upper` is near-top against the spec return
  upper bound `s_hi` (DESIGN.md 3.1 step 8): `upper` contains `term()`
  minus a finite set of atoms (`dynamic(not :undefined)`,
  `dynamic(not false and not nil)`), or `upper − s_hi` contains all of
  `pid()`, `port()`, `reference()` and `fun()` whole (no ordinary code
  returns those by accident; their presence means inference gave up, as
  in `dynamic(not [])`). A top `upper` is near-top too; callers that need
  to tell the two apart check top first. An empty `upper` is not.
  """
  @spec near_top?(Compiler.descr(), Compiler.descr()) :: boolean()
  def near_top?(upper, s_hi) do
    upper = Compiler.upper_bound(upper)
    missing = Compiler.difference(Compiler.term(), upper)

    cond do
      Compiler.empty?(upper) ->
        false

      Compiler.subtype?(missing, Compiler.atom()) and
          match?({:finite, _}, Compiler.atom_fetch(missing)) ->
        true

      Compiler.empty?(missing) ->
        true

      true ->
        extra = Compiler.difference(upper, s_hi)

        Enum.all?(
          [Compiler.pid(), Compiler.port(), Compiler.reference(), Compiler.fun()],
          &Compiler.subtype?(&1, extra)
        )
    end
  end

  @doc """
  The all-`dynamic()` argument probe: what the checker predicts for a call
  site that knows nothing about its arguments, related to the union of the
  spec slices' return upper bounds.
  """
  @spec dynamic_probe([Compiler.clause()], arity(), [Compiler.descr()]) :: probe()
  def dynamic_probe(clauses, arity, spec_returns) do
    case Compiler.apply_infer(clauses, List.duplicate(Compiler.dynamic(), arity)) do
      :error ->
        %{applied: :badapply, return: Compiler.none(), relation: :badapply}

      {used, type} ->
        upper = Compiler.upper_bound(type)

        %{
          applied: {:ok, Enum.sort(used)},
          return: upper,
          relation: relation(upper, Compiler.union_all(spec_returns))
        }
    end
  end

  @doc """
  Set relation of `left` to `right`: `:subset` means `left ⊂ right`
  strictly, `:empty` means at least one side is empty.
  """
  @spec relation(Compiler.descr(), Compiler.descr()) :: relation()
  def relation(left, right) do
    sub? = Compiler.subtype?(left, right)
    super? = Compiler.subtype?(right, left)

    cond do
      Compiler.empty?(left) or Compiler.empty?(right) -> :empty
      sub? and super? -> :equal
      sub? -> :subset
      super? -> :superset
      Compiler.disjoint?(left, right) -> :disjoint
      true -> :overlapping
    end
  end

  # Contributing clauses, in clause order. Containment is decided on whole
  # argument tuples. Not contained in D_hi means not contained in D (D ⊆ D_hi),
  # so an escape is certain even with losses. Containment in D_lo implies
  # containment in D (D_lo ⊆ D); containment in D_hi alone implies it only
  # when no argument lost precision (then D_lo = D = D_hi).
  defp contributing(clauses, used, spec_domain, input_approximate?, d_lo) do
    used_set = MapSet.new(used)
    spec_domain_lo = Compiler.tuple(d_lo)
    shadowed = MapSet.new(shadowed(clauses))

    for {{args, return}, index} <- Enum.with_index(clauses), MapSet.member?(used_set, index) do
      clause_domain = args |> Enum.map(&Compiler.upper_bound/1) |> Compiler.tuple()

      containment =
        cond do
          not Compiler.subtype?(clause_domain, spec_domain) -> :domain_escape
          not input_approximate? -> :contained
          Compiler.subtype?(clause_domain, spec_domain_lo) -> :contained
          true -> :containment_unknown
        end

      %{
        index: index,
        args: args,
        return: return,
        static_return?: not Compiler.gradual?(return),
        containment: containment,
        shadowed?: MapSet.member?(shadowed, index)
      }
    end
  end

  @doc """
  Indexes of the inferred clauses that may be unreachable (DESIGN.md 3.1
  step 7, the prerequisite "the compiler did not already flag the clause
  unreachable"): clause `k` is shadowed when the upper bound of its domain
  tuple is a subtype of the union of the domain tuples of clauses `0..k-1`.

  The checker chunk does not record reachability, and stored clause
  domains over-approximate guarded clauses, so this over-reports: it never
  misses a clause the compiler reports as redundant, and it may flag a
  clause whose earlier clauses only match part of their stored domain
  because of guards.
  """
  @spec shadowed([Compiler.clause()]) :: [non_neg_integer()]
  def shadowed(clauses) do
    {indexes, _seen} =
      clauses
      |> Enum.with_index()
      |> Enum.reduce({[], nil}, fn {{args, _return}, index}, {acc, seen} ->
        domain = args |> Enum.map(&Compiler.upper_bound/1) |> Compiler.tuple()

        cond do
          seen == nil -> {acc, domain}
          Compiler.subtype?(domain, seen) -> {[index | acc], seen}
          true -> {acc, Compiler.union(seen, domain)}
        end
      end)

    Enum.reverse(indexes)
  end

  defp inferred_domain(clauses, arity) do
    Enum.reduce(clauses, List.duplicate(Compiler.none(), arity), fn {args, _return}, acc ->
      Enum.zip_with(Enum.map(args, &Compiler.upper_bound/1), acc, &Compiler.union/2)
    end)
  end

  defp domain_overlap?(spec_domain, clauses) do
    Enum.any?(clauses, fn {args, _return} ->
      clause_domain = args |> Enum.map(&Compiler.upper_bound/1) |> Compiler.tuple()
      not Compiler.disjoint?(spec_domain, clause_domain)
    end)
  end

  # An unsupported sibling was never interpreted: its overlap is :no only
  # when the upper bounds of its arguments are disjoint from the slice's,
  # otherwise :unknown (never :yes, its lower bounds are unknown).
  defp sibling_overlap(_args, {:unsupported, nil}), do: :unknown

  defp sibling_overlap(args, {:unsupported, bounds}) do
    if length(bounds) == length(args) and disjoint_upper?(args, bounds),
      do: :no,
      else: :unknown
  end

  defp sibling_overlap(args, %{args: other_args}), do: overlap(args, other_args)

  # Whether the argument tuples are disjoint, from their upper bounds alone.
  defp disjoint_upper?(args, other_args) do
    hi = args |> Enum.map(& &1.hi) |> Compiler.tuple()
    other_hi = other_args |> Enum.map(& &1.hi) |> Compiler.tuple()

    Compiler.empty?(hi) or Compiler.disjoint?(hi, other_hi) or
      Enum.any?(Enum.zip(args, other_args), &integers_disjoint?/1)
  end

  # :yes, :no or :unknown (see the moduledoc).
  defp overlap(args, other_args) do
    lo = args |> Enum.map(& &1.lo) |> Compiler.tuple()
    other_lo = other_args |> Enum.map(& &1.lo) |> Compiler.tuple()

    cond do
      disjoint_upper?(args, other_args) -> :no
      not Compiler.disjoint?(lo, other_lo) -> :yes
      true -> :unknown
    end
  end

  # One argument position proves the tuples disjoint when its upper bounds
  # share only integers and the integer intervals are disjoint.
  defp integers_disjoint?({left, right}) do
    shared = Compiler.intersection(left.hi, right.hi)

    Compiler.subtype?(shared, Compiler.integer()) and
      Bound.intervals_disjoint?(Bound.integer_intervals(left), Bound.integer_intervals(right))
  end
end
