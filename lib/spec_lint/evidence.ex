defmodule SpecLint.Evidence do
  @moduledoc """
  The structured extra-return classifier behind `SL002` (DESIGN.md 3.1).

  `classify/2` takes the raw relations of one spec slice
  (`SpecLint.Compare.relations/0`) and returns an evidence class, the
  labelled components of the slice's `extra` and the reasons behind the
  class. It is a conservative recogniser with an explicit `:unknown`
  result, not a complete definition; it gates nothing by itself.

  Steps, in DESIGN order:

    1. `extra = U(D) − S_hi`; empty means `:none`. A slice where no inferred
       clause applies (`:badapply`) has no applied return and is `:none`
       with reason `:badapply`.
    2. Top-only inference (`U(D) ⊇ term()`) is `:unknown`.
    3. Domain containment of each contributing clause is read from the
       relations (`:contained`, `:domain_escape`, `:containment_unknown`).
    4. Input approximation is the slice's `input_approximate?`.
    5. The upper bounds of `extra` and of every contributing clause return
       are split into components through the adapter
       (`SpecLint.Compiler.components/1`) and labelled:
         * `:structured` - a finite atom set; `[]`; a closed tuple of fixed
           arity whose first element is a finite atom set; a closed map
           with only literal keys, or a map whose required `__struct__`
           field is a finite atom set (a struct); a proper list whose
           element type has only `:structured` components;
         * `:whole_kind` - an entire base kind (`integer()`, `binary()`,
           `tuple()`, `map()`, `fun()`, `atom()`, lists of `term()`, ...);
         * `:unknown` - anything else, including every component with an
           intersection or a negation the adapter could not eliminate,
           at its top or anywhere inside it (for example
           `{:error, term() and not atom()}`).
       A component of `extra` is `present_in_contributing?` when it is a
       subset of the union of the contributing clause return components
       with the same label. Only present components count as evidence, so
       structure created by subtracting the spec is never mistaken for
       structure inferred from code.
    6. Classification, over counted components:
         * `:structured_possible` - at least one structured component, every
           contributing clause contained, slice not input-approximate;
         * `:possible_domain_escape` - a structured component and some
           contributing clause certainly escapes the spec domain;
         * `:possible_input_approximate` - a structured component, no
           certain escape, and the slice's inputs were widened by
           translation (so containment is unknown);
         * `:whole_kind_possible` - no counted structured component and at
           least one counted whole-kind component;
         * `:unknown` - anything else.

  Two readings of DESIGN 3.1 are fixed here. A certain escape takes
  precedence over input approximation: an escape is a fact about the
  clause domain that holds for every refinement of `D_hi`, while
  approximation only makes containment undecidable (Compare reports
  `:containment_unknown` for a contained clause of an approximate slice,
  and `:domain_escape` only when the clause escapes `D_hi` itself). And a
  mix of whole-kind and unknown components, with no structured one, is
  `:whole_kind_possible`: the whole-kind component is real evidence and the
  unknown ones are listed in the components.

  Context that does not change the class but that rules need is recorded
  in `reasons`: `:overlap`, `:spec_return_empty`, `:return_inexact`,
  `:cutoff`. For measurement, a structured component whose tag (the first
  element of a tuple of the same arity, or a struct name) already occurs
  in `S_hi` is marked `tag_in_spec?` and counted as `{:tag_in_spec, n}`:
  such an extra is a wider payload under a declared tag, often caused by
  imprecise inference of the payload, rather than a new alternative.
  """

  alias SpecLint.{Compare, Compiler}

  @typedoc "Evidence class of one slice or one function."
  @type class ::
          :none
          | :unknown
          | :structured_possible
          | :possible_domain_escape
          | :possible_input_approximate
          | :whole_kind_possible

  @typedoc "Label of one component."
  @type label :: :structured | :whole_kind | :unknown

  @typedoc "One labelled component of `extra`."
  @type component :: %{
          descr_string: String.t(),
          kind: Compiler.kind(),
          label: label(),
          present_in_contributing?: boolean(),
          detail: atom() | nil,
          tag_in_spec?: boolean()
        }

  @typedoc "Why a slice got its class, plus context rules need."
  @type reason ::
          :no_extra
          | :badapply
          | :top_only
          | :cutoff
          | :input_approximate
          | :overlap
          | :spec_return_empty
          | :return_inexact
          | :no_counted_component
          | {:domain_escape, [non_neg_integer()]}
          | {:containment_unknown, [non_neg_integer()]}
          | {:not_in_contributing, non_neg_integer()}
          | {:unknown_components, non_neg_integer()}
          | {:tag_in_spec, non_neg_integer()}

  @typedoc "Result of `classify/2`."
  @type classification :: %{class: class(), components: [component()], reasons: [reason()]}

  # Worst first: the order in which a function-level class is chosen.
  @severity [
    :structured_possible,
    :possible_domain_escape,
    :possible_input_approximate,
    :whole_kind_possible,
    :unknown,
    :none
  ]

  @default_depth 3

  @doc "All classes, worst first."
  @spec classes() :: [class(), ...]
  def classes, do: @severity

  @doc """
  Classifies one slice from its relations.

  Options:

    * `:depth` - how deep list element types are inspected when deciding
      whether a list is structured (default #{@default_depth}).
  """
  @spec classify(Compare.relations(), keyword()) :: classification()
  def classify(relations, opts \\ []) do
    depth = Keyword.get(opts, :depth, @default_depth)
    context = context_reasons(relations)

    cond do
      relations.applied == :badapply ->
        result(:none, [], [:badapply | context])

      Compiler.empty?(relations.extra) ->
        result(:none, [], [:no_extra | context])

      relations.top_only? ->
        result(:unknown, [], [:top_only | context])

      true ->
        recognise(relations, depth, context)
    end
  end

  @doc """
  Reduces the classes of a function's slices to one class, worst first:
  `structured_possible > possible_domain_escape > possible_input_approximate
  > whole_kind_possible > unknown > none`.

  Each element is a classification (as returned by `classify/2`), a bare
  class, the relations of a slice (classified with `opts`), or a slice of
  `SpecLint.Analysis` (its relations are classified; a slice without
  relations, i.e. unsupported or unavailable, is skipped). A function with
  no classified slice is `:none`; coverage of such slices is the ledger's
  business, not evidence.
  """
  @spec classify_function([classification() | class() | map()], keyword()) :: class()
  def classify_function(slices, opts \\ []) do
    slices
    |> Enum.flat_map(&slice_class(&1, opts))
    |> worst()
  end

  @doc "The worst of `classes` in the order of `classify_function/2`; `:none` for `[]`."
  @spec worst([class()]) :: class()
  def worst(classes), do: Enum.find(@severity, :none, &(&1 in classes))

  defp slice_class(class, _opts) when is_atom(class), do: [class]
  defp slice_class(%{class: class}, _opts), do: [class]
  defp slice_class(%{relations: nil}, _opts), do: []
  defp slice_class(%{relations: relations}, opts), do: [classify(relations, opts).class]
  defp slice_class(%{extra: _} = relations, opts), do: [classify(relations, opts).class]

  defp result(class, components, reasons),
    do: %{class: class, components: components, reasons: reasons}

  defp context_reasons(relations) do
    [
      relations.overlap? && :overlap,
      relations.spec_return_empty? && :spec_return_empty,
      not relations.return_exact? && :return_inexact,
      relations.cutoff? && :cutoff
    ]
    |> Enum.filter(& &1)
  end

  defp recognise(relations, depth, context) do
    returns =
      relations.contributing
      |> Enum.flat_map(&Compiler.components(Compiler.upper_bound(&1.return)))
      |> Enum.map(&{label(&1, depth), &1.descr})

    # S_hi = missing ∪ (U(D) − extra), since missing = S_hi − U(D).
    spec_return =
      Compiler.union(
        relations.missing,
        Compiler.difference(relations.applied_upper, relations.extra)
      )

    components =
      relations.extra
      |> Compiler.components()
      |> Enum.map(fn component ->
        label = label(component, depth)

        %{
          descr_string: Compiler.to_string(component.descr),
          kind: component.kind,
          label: label,
          present_in_contributing?: present?(component.descr, label, returns),
          detail: detail(component.view),
          tag_in_spec?: label == :structured and tag_in_spec?(component.view, spec_return)
        }
      end)

    counted = for %{present_in_contributing?: true, label: label} <- components, do: label
    structured? = :structured in counted
    escapes = containment(relations, :domain_escape)
    unknown_containment = containment(relations, :containment_unknown)

    class =
      cond do
        structured? and escapes != [] -> :possible_domain_escape
        structured? and relations.input_approximate? -> :possible_input_approximate
        structured? and unknown_containment != [] -> :possible_domain_escape
        structured? -> :structured_possible
        :whole_kind in counted -> :whole_kind_possible
        true -> :unknown
      end

    reasons =
      [
        relations.input_approximate? && :input_approximate,
        escapes != [] && {:domain_escape, escapes},
        unknown_containment != [] && {:containment_unknown, unknown_containment},
        uncounted(components),
        unknown_count(components),
        tag_in_spec_count(components),
        class == :unknown && :no_counted_component
      ]
      |> Enum.filter(& &1)

    result(class, components, reasons ++ context)
  end

  defp containment(relations, outcome),
    do: for(%{containment: ^outcome, index: index} <- relations.contributing, do: index)

  defp uncounted(components) do
    case Enum.count(components, &(&1.label != :unknown and not &1.present_in_contributing?)) do
      0 -> false
      n -> {:not_in_contributing, n}
    end
  end

  defp tag_in_spec_count(components) do
    case Enum.count(components, & &1.tag_in_spec?) do
      0 -> false
      n -> {:tag_in_spec, n}
    end
  end

  # Whether the spec return already has a value with the component's tag:
  # a tuple of the same arity and first element, or a struct of the same
  # name. The extra is then a wider payload under a declared tag rather
  # than a new alternative. Informational: it does not change the class.
  defp tag_in_spec?({:tuple, :closed, [tag | rest]}, spec_return) do
    shape = Compiler.tuple([tag | Enum.map(rest, fn _ -> Compiler.term() end)])
    not Compiler.disjoint?(shape, spec_return)
  end

  defp tag_in_spec?({:map, _tag, fields, _domains}, spec_return) do
    case List.keyfind(fields, :__struct__, 0) do
      {:__struct__, name, false} ->
        shape =
          Compiler.closed_map([{:__struct__, name, false}], [{all_key_kinds(), Compiler.term()}])

        not Compiler.disjoint?(shape, spec_return)

      _ ->
        false
    end
  end

  defp tag_in_spec?(_view, _spec_return), do: false

  defp all_key_kinds do
    [:atom, :binary, :bitstring_no_binary, :float, :fun, :integer, :list, :map] ++
      [:pid, :port, :reference, :tuple]
  end

  defp unknown_count(components) do
    case Enum.count(components, &(&1.label == :unknown)) do
      0 -> false
      n -> {:unknown_components, n}
    end
  end

  defp present?(descr, label, returns) do
    same = for {^label, return} <- returns, do: return
    same != [] and Compiler.subtype?(descr, Compiler.union_all(same))
  end

  defp detail({:unknown, _kind, reason}), do: reason
  defp detail({:whole, _kind}), do: nil
  defp detail({:atoms, _atoms}), do: :atoms
  defp detail(:empty_list), do: :empty_list
  defp detail({:tuple, _tag, _elements}), do: :tuple
  defp detail({:map, _tag, _fields, _domains}), do: :map
  defp detail({:list, _element, _tail, _empty?}), do: :list

  @doc """
  Labels one adapter component (`SpecLint.Compiler.component/0`) as
  `:structured`, `:whole_kind` or `:unknown`. `depth` bounds the
  inspection of list element types.
  """
  @spec label(Compiler.component(), non_neg_integer()) :: label()
  def label(%{view: view}, depth), do: view_label(view, depth)

  defp view_label({:whole, _kind}, _depth), do: :whole_kind
  defp view_label({:atoms, _atoms}, _depth), do: :structured
  defp view_label(:empty_list, _depth), do: :structured
  defp view_label({:unknown, _kind, _reason}, _depth), do: :unknown

  defp view_label({:tuple, :closed, [first | _] = elements}, _depth) do
    if finite_atoms?(first) and Enum.all?(elements, &clean?/1),
      do: :structured,
      else: :unknown
  end

  defp view_label({:tuple, _tag, _elements}, _depth), do: :unknown

  defp view_label({:map, tag, fields, domains}, _depth) do
    struct? =
      Enum.any?(fields, fn {key, value, optional?} ->
        key == :__struct__ and not optional? and finite_atoms?(value)
      end)

    clean? = Enum.all?(fields, fn {_key, value, _optional?} -> clean?(value) end)

    if clean? and (struct? or (tag == :closed and domains == [])),
      do: :structured,
      else: :unknown
  end

  defp view_label({:list, element, tail, _empty?}, depth) do
    cond do
      Compiler.subtype?(Compiler.term(), element) -> :whole_kind
      not Compiler.subtype?(tail, Compiler.empty_list()) -> :unknown
      structured_element?(element, depth) -> :structured
      true -> :unknown
    end
  end

  defp structured_element?(_element, 0), do: false

  defp structured_element?(element, depth) do
    case Compiler.components(element) do
      [] -> false
      components -> Enum.all?(components, &(label(&1, depth - 1) == :structured))
    end
  end

  defp finite_atoms?(descr), do: match?({:finite, [_ | _]}, Compiler.atom_fetch(descr))

  # DESIGN 3.1: an intersection or a negation anywhere inside a component
  # makes it unknown, not only at its top. A type is clean when none of its
  # components, at any depth up to the clean-depth budget, is an
  # intersection or a negation the adapter could not eliminate. Past the
  # budget a type is not considered clean; `term()` always is.
  @clean_depth 6

  defp clean?(descr), do: clean?(descr, @clean_depth)

  defp clean?(descr, budget) do
    cond do
      Compiler.subtype?(Compiler.term(), descr) ->
        true

      budget == 0 ->
        false

      true ->
        descr
        |> Compiler.components()
        |> Enum.all?(fn %{view: view} ->
          case view do
            {:unknown, _kind, reason} when reason in [:negation, :intersection] -> false
            view -> view |> children() |> Enum.all?(&clean?(&1, budget - 1))
          end
        end)
    end
  end

  defp children({:tuple, _tag, elements}), do: elements

  defp children({:map, _tag, fields, domains}),
    do: Enum.map(fields, &elem(&1, 1)) ++ Enum.map(domains, &elem(&1, 1))

  defp children({:list, element, tail, _empty?}), do: [element, tail]
  defp children(_view), do: []
end
