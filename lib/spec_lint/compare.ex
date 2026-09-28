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

  @typedoc "An inferred clause that the application rule selected for a slice."
  @type contributing :: %{
          index: non_neg_integer(),
          args: [Compiler.descr()],
          return: Compiler.descr(),
          static_return?: boolean(),
          containment: containment()
        }

  @typedoc "Per-position relation of the spec argument to the inferred domain."
  @type domain_relation :: %{spec: relation(), inferred: Compiler.descr()}

  @typedoc "Relations for one spec slice."
  @type relations :: %{
          applied: {:ok, [non_neg_integer()]} | :badapply,
          applied_return: Compiler.descr(),
          applied_upper: Compiler.descr(),
          cutoff?: boolean(),
          top_only?: boolean(),
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
          contributing: [contributing()],
          input_approximate?: boolean()
        }

  @typedoc "Result of the all-`dynamic()` argument probe."
  @type probe :: %{
          applied: {:ok, [non_neg_integer()]} | :badapply,
          return: Compiler.descr(),
          relation: relation() | :badapply
        }

  @typedoc "A translated slice, or the reason it could not be translated."
  @type slice_input :: {:ok, SpecLint.Translate.slice()} | {:unsupported, term()}

  @doc """
  Compares every slice of one function. Unsupported slices are passed
  through; they still count for nothing else (overlap is computed among
  translated slices only).
  """
  @spec function([slice_input()], [Compiler.clause()], arity()) :: %{
          slices: [{:ok, relations()} | {:unsupported, term()}],
          dynamic_probe: probe()
        }
  def function(slices, clauses, arity) do
    translated = for {{:ok, slice}, index} <- Enum.with_index(slices), do: {index, slice}

    results =
      slices
      |> Enum.with_index()
      |> Enum.map(fn
        {{:ok, slice}, index} ->
          others = for {other, s} <- translated, other != index, do: {other, s}
          {:ok, slice(slice, clauses, others)}

        {{:unsupported, reason}, _index} ->
          {:unsupported, reason}
      end)

    spec_returns = for {_index, slice} <- translated, do: slice.return.hi
    %{slices: results, dynamic_probe: dynamic_probe(clauses, arity, spec_returns)}
  end

  @doc """
  Relations for one translated slice against the inferred `clauses`.
  `others` are the function's other translated slices with their indexes,
  used for the overlap tag.
  """
  @spec slice(SpecLint.Translate.slice(), [Compiler.clause()], [
          {non_neg_integer(), SpecLint.Translate.slice()}
        ]) :: relations()
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
    overlaps_with = for {index, other} <- others, overlaps?(spec_domain, other), do: index

    %{
      applied: applied,
      applied_return: applied_return,
      applied_upper: upper,
      cutoff?: length(used) > Compiler.max_clauses(),
      top_only?: applied != :badapply and Compiler.subtype?(Compiler.term(), upper),
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
      contributing: contributing(clauses, used, spec_domain, input_approximate?, d_lo),
      input_approximate?: input_approximate?
    }
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
        containment: containment
      }
    end
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

  defp overlaps?(spec_domain, %{args: args}) do
    other = args |> Enum.map(& &1.hi) |> Compiler.tuple()
    not Compiler.empty?(spec_domain) and not Compiler.disjoint?(spec_domain, other)
  end
end
