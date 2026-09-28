defmodule SpecLint.Evidence do
  @moduledoc """
  The structured extra-return classifier behind `SL002`, and the per-clause
  conflict evidence reported under `SL001` (DESIGN.md 3.1).

  `classify/2` takes the raw relations of one spec slice
  (`SpecLint.Compare.relations/0`) and returns an evidence class, the
  labelled components of the slice's `extra`, the reasons behind the class
  and one entry per contributing inferred clause. It is a conservative
  recogniser with an explicit `:unknown` result, not a complete definition;
  it gates nothing by itself.

  Steps, in DESIGN order:

    1. `extra = U(D) − S_hi`; empty means `:none`. A slice where no inferred
       clause applies (`:badapply`) has no applied return and is `:none`
       with reason `:badapply`.
    2. Top-only inference (`U(D) ⊇ term()`) is `:unknown` at the union
       level, with reason `:top_only`.
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
       structure inferred from code. That includes a payload refined by
       the subtraction: a structured component whose tag is already in
       `S_hi` (`tag_in_spec?`) is `subtraction_payload?`, and not present,
       when every contributing return component with the same label that
       it overlaps has `term()` at a position (tuple element or struct
       field, looked up to three levels deep) where the component is
       narrower, and widening those positions back to `term()` makes the
       component meet `S_hi` (so it is outside the spec only because of
       them). `{:ok, not pid()}` from a clause returning `{:ok, term()}`
       under a spec `{:ok, pid()}` says nothing about the code beyond
       `{:ok, _}`, which the spec already declares; `{:ok, pid(), :b}` from
       `{:ok, term(), :a or :b}` under `{:ok, pid(), :a}` still counts,
       because `:b` comes from the code.
    6. Union-level classification, over counted components:
         * `:structured_possible` - at least one structured component, every
           contributing clause contained, slice not input-approximate;
         * `:possible_domain_escape` - a structured component and some
           contributing clause certainly escapes the spec domain;
         * `:possible_input_approximate` - a structured component, no
           certain escape, and the slice's inputs were widened by
           translation (so containment is unknown);
         * `:whole_kind_possible` - no counted structured component, at
           least one counted whole-kind component, every contributing
           clause contained and the slice not input-approximate. With a
           certain escape the class is `:possible_domain_escape`, with
           input approximation `:possible_input_approximate`, and the
           reason `:whole_kind_only` records that the evidence is whole
           kinds only (Phase 0 bug O6);
         * `:unknown` - anything else.
    7. Per-clause evidence. Every contributing clause `k` is examined on
       its own, with `R_k' = upper_bound(R_k)` of the stored clause return
       (never the wrapped application result):
         * `R_k'` empty is `:none`; `R_k'` top or near-top is `:unknown`;
           `R_k' ⊆ S_hi` is `:none`;
         * `R_k'` disjoint from `S_hi` is `:clause_conflict` when the clause
           is contained: every normal return of the clause, whose inputs
           are all inside the spec domain, is outside the spec. A spec
           return of `none()` is `SL006`'s case and never a conflict;
         * otherwise `R_k' − S_hi` is classified with step 5 against `R_k`
           alone (structure must be present in `R_k` itself), giving
           `:structured_possible`, `:whole_kind_possible` or `:unknown`.
       A clause that is not contained never yields `:clause_conflict` or
       `:structured_possible`: with `:domain_escape` its evidence is capped
       at `:possible_domain_escape`, with `:containment_unknown` (Compare
       reports it only when input approximation hides containment) at
       `:possible_input_approximate`, the same reading as the union level.
       The slice class is the worst of the union-level class and every
       per-clause class. Whether the compiler would flag a clause as
       unreachable is not available from the checker chunk. A clause whose
       domain is covered by the clauses before it
       (`SpecLint.Compare.shadowed/1`) gets the reason `:possibly_shadowed`
       and keeps its class; the prerequisite of DESIGN 3.1 step 7 is
       decided by the rule (`SpecLint.Rules.ReturnConflict`).
    8. Near-top (`SpecLint.Compare.near_top?/2`) is treated like top-only,
       at the union level (reason `:near_top`) and per clause.
    9. Gradual payloads. A counted structured component that no static
       contributing clause return witnesses (`Compiler.gradual?/1` on the
       stored clause return, `static_return?` in the relations) is
       `payload_gradual?`. With the option `require_static_return: true`, a
       class that would be `:structured_possible` only because of such
       components is `:possible_gradual`, and so is a `:clause_conflict`
       whose clause return is gradual. The option does not change any
       other class. The default is `false`.

  One more reading of DESIGN 3.1 is fixed here. A certain escape takes
  precedence over input approximation: an escape is a fact about the
  clause domain that holds for every refinement of `D_hi`, while
  approximation only makes containment undecidable. A mix of whole-kind
  and unknown components, with no structured one, is `:whole_kind_possible`:
  the whole-kind component is real evidence and the unknown ones are
  listed in the components.

  Context that does not change the class but that rules need is recorded
  in `reasons`: `:overlap`, `:overlap_unknown`, `:spec_return_empty`,
  `:return_inexact`, `:cutoff`. For measurement, a structured component
  whose tag (the first element of a tuple of the same arity, or a struct
  name) already occurs in `S_hi` is marked `tag_in_spec?` and counted as
  `{:tag_in_spec, n}`: such an extra is a wider payload under a declared
  tag, often caused by imprecise inference of the payload, rather than a
  new alternative.
  """

  alias SpecLint.{Compare, Compiler}

  @typedoc "Evidence class of one slice, one clause or one function."
  @type class ::
          :none
          | :unknown
          | :clause_conflict
          | :structured_possible
          | :possible_gradual
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
          tag_in_spec?: boolean(),
          subtraction_payload?: boolean(),
          payload_gradual?: boolean()
        }

  @typedoc "Why a slice or a clause got its class, plus context rules need."
  @type reason ::
          :no_extra
          | :no_return
          | :badapply
          | :top_only
          | :near_top
          | :cutoff
          | :input_approximate
          | :overlap
          | :overlap_unknown
          | :spec_return_empty
          | :return_inexact
          | :no_counted_component
          | :whole_kind_only
          | :disjoint
          | :payload_gradual
          | :possibly_shadowed
          | {:domain_escape, [non_neg_integer()]}
          | {:containment_unknown, [non_neg_integer()]}
          | {:not_in_contributing, non_neg_integer()}
          | {:unknown_components, non_neg_integer()}
          | {:tag_in_spec, non_neg_integer()}
          | {:subtraction_payload, non_neg_integer()}
          | {:payload_gradual, non_neg_integer()}

  @typedoc "Per-clause evidence (DESIGN 3.1 step 7) for one contributing clause."
  @type clause_evidence :: %{
          index: non_neg_integer(),
          containment: Compare.containment(),
          static_return?: boolean(),
          class: class(),
          extra: Compiler.descr(),
          components: [component()],
          reasons: [reason()]
        }

  @typedoc """
  Result of `classify/2`: the slice class (worst of the union-level class
  and every per-clause class), the union-level class with its components
  and reasons, and the per-clause evidence.
  """
  @type classification :: %{
          class: class(),
          union_class: class(),
          components: [component()],
          reasons: [reason()],
          clauses: [clause_evidence()]
        }

  # Worst first: the order in which a slice or function class is chosen.
  @severity [
    :clause_conflict,
    :structured_possible,
    :possible_gradual,
    :possible_domain_escape,
    :possible_input_approximate,
    :whole_kind_possible,
    :unknown,
    :none
  ]

  @default_depth 3

  # How deep nested tuples and structs are compared when deciding whether a
  # payload was refined only by subtracting the spec.
  @subtraction_depth 3

  @doc "All classes, worst first."
  @spec classes() :: [class(), ...]
  def classes, do: @severity

  @doc """
  Classifies one slice from its relations.

  Options:

    * `:depth` - how deep list element types are inspected when deciding
      whether a list is structured (default #{@default_depth});
    * `:require_static_return` - downgrade structured evidence and clause
      conflicts that only gradual clause returns support to
      `:possible_gradual` (DESIGN 3.1 step 9, default `false`).
  """
  @spec classify(Compare.relations(), keyword()) :: classification()
  def classify(relations, opts \\ []) do
    settings = %{
      depth: Keyword.get(opts, :depth, @default_depth),
      static?: Keyword.get(opts, :require_static_return, false)
    }

    context = context_reasons(relations)

    cond do
      relations.applied == :badapply ->
        result(:none, [], [:badapply | context], [])

      Compiler.empty?(relations.extra) ->
        result(:none, [], [:no_extra | context], [])

      true ->
        {union_class, components, reasons} = union_level(relations, settings)
        clauses = Enum.map(relations.contributing, &clause(&1, relations, settings))
        result(union_class, components, reasons ++ context, clauses)
    end
  end

  @doc """
  Reduces the classes of a function's slices to one class, worst first, in
  the order of `classes/0`.

  Each element is a classification (as returned by `classify/2`), a bare
  class, the relations of a slice (classified with `opts`), or a slice of
  `SpecLint.Analysis` (its relations are classified with `opts`; a slice
  without relations, i.e. unsupported or unavailable, is skipped). A
  function with no classified slice is `:none`; coverage of such slices is
  the ledger's business, not evidence.
  """
  @spec classify_function([classification() | class() | map()], keyword()) :: class()
  def classify_function(slices, opts \\ []) do
    slices
    |> Enum.flat_map(&slice_class(&1, opts))
    |> worst()
  end

  @doc "The worst of `classes` in the order of `classes/0`; `:none` for `[]`."
  @spec worst([class()]) :: class()
  def worst(classes), do: Enum.find(@severity, :none, &(&1 in classes))

  defp slice_class(class, _opts) when is_atom(class), do: [class]
  defp slice_class(%{class: class}, _opts), do: [class]
  defp slice_class(%{relations: nil}, _opts), do: []
  defp slice_class(%{relations: relations}, opts), do: [classify(relations, opts).class]
  defp slice_class(%{extra: _} = relations, opts), do: [classify(relations, opts).class]

  defp result(union_class, components, reasons, clauses) do
    %{
      class: worst([union_class | Enum.map(clauses, & &1.class)]),
      union_class: union_class,
      components: components,
      reasons: reasons,
      clauses: clauses
    }
  end

  defp context_reasons(relations) do
    [
      relations.overlap? && :overlap,
      relations.overlap_unknown? && :overlap_unknown,
      relations.spec_return_empty? && :spec_return_empty,
      not relations.return_exact? && :return_inexact,
      relations.cutoff? && :cutoff
    ]
    |> Enum.filter(& &1)
  end

  ## Union level (steps 2 to 6, 8 and 9)

  defp union_level(%{top_only?: true}, _settings), do: {:unknown, [], [:top_only]}
  defp union_level(%{near_top?: true}, _settings), do: {:unknown, [], [:near_top]}

  defp union_level(relations, settings) do
    returns = Enum.flat_map(relations.contributing, &witnesses/1)
    components = components(relations.extra, returns, relations.spec_return, settings.depth)
    escapes = containment(relations, :domain_escape)
    unknown_containment = containment(relations, :containment_unknown)

    doubt =
      cond do
        escapes != [] -> :possible_domain_escape
        relations.input_approximate? -> :possible_input_approximate
        unknown_containment != [] -> :possible_domain_escape
        true -> nil
      end

    {class, class_reasons} = decide(components, doubt, settings)

    reasons =
      [
        relations.input_approximate? && :input_approximate,
        escapes != [] && {:domain_escape, escapes},
        unknown_containment != [] && {:containment_unknown, unknown_containment}
      ]
      |> Enum.filter(& &1)

    {class, components, reasons ++ component_reasons(components) ++ class_reasons}
  end

  ## Per clause (step 7)

  defp clause(contributing, relations, settings) do
    upper = Compiler.upper_bound(contributing.return)
    s_hi = relations.spec_return
    extra = Compiler.difference(upper, s_hi)

    base = %{
      index: contributing.index,
      containment: contributing.containment,
      static_return?: contributing.static_return?,
      extra: extra,
      components: []
    }

    {class, components, reasons} =
      cond do
        Compiler.empty?(upper) ->
          {:none, [], [:no_return]}

        Compiler.subtype?(Compiler.term(), upper) ->
          {:unknown, [], [:top_only]}

        Compare.near_top?(upper, s_hi) ->
          {:unknown, [], [:near_top]}

        Compiler.empty?(extra) ->
          {:none, [], [:no_extra]}

        Compiler.disjoint?(upper, s_hi) and not relations.spec_return_empty? ->
          conflict(contributing, settings)

        true ->
          returns = witnesses(contributing)
          components = components(extra, returns, s_hi, settings.depth)
          {class, class_reasons} = decide(components, clause_doubt(contributing), settings)
          {class, components, component_reasons(components) ++ class_reasons}
      end

    reasons = containment_reason(contributing) ++ shadow_reason(contributing) ++ reasons
    Map.merge(base, %{class: class, components: components, reasons: reasons})
  end

  defp shadow_reason(%{shadowed?: true}), do: [:possibly_shadowed]
  defp shadow_reason(_contributing), do: []

  defp containment_reason(%{containment: :contained}), do: []
  defp containment_reason(%{containment: outcome, index: index}), do: [{outcome, [index]}]

  defp conflict(%{containment: :contained, static_return?: false}, %{static?: true}),
    do: {:possible_gradual, [], [:disjoint, :payload_gradual]}

  defp conflict(%{containment: :contained}, _settings), do: {:clause_conflict, [], [:disjoint]}

  defp conflict(contributing, _settings), do: {clause_doubt(contributing), [], [:disjoint]}

  defp clause_doubt(%{containment: :contained}), do: nil
  defp clause_doubt(%{containment: :domain_escape}), do: :possible_domain_escape
  defp clause_doubt(%{containment: :containment_unknown}), do: :possible_input_approximate

  ## Shared

  # Class from counted components. `doubt` is the possible_* class that
  # replaces a positive class when containment is not established.
  defp decide(components, doubt, settings) do
    counted = for %{present_in_contributing?: true} = component <- components, do: component
    structured = for %{label: :structured} = component <- counted, do: component
    whole? = Enum.any?(counted, &(&1.label == :whole_kind))
    static_structured? = Enum.any?(structured, &(not &1.payload_gradual?))

    cond do
      structured != [] and doubt != nil -> {doubt, []}
      structured != [] and settings.static? and not static_structured? -> {:possible_gradual, []}
      structured != [] -> {:structured_possible, []}
      whole? and doubt != nil -> {doubt, [:whole_kind_only]}
      whole? -> {:whole_kind_possible, []}
      true -> {:unknown, [:no_counted_component]}
    end
  end

  # Return components of one contributing clause, labelled, with whether the
  # stored clause return is static.
  defp witnesses(contributing) do
    for component <- Compiler.components(Compiler.upper_bound(contributing.return)) do
      {component, contributing.static_return?}
    end
  end

  defp components(extra, witnesses, spec_return, depth) do
    returns =
      for {component, static?} <- witnesses,
          do: {label(component, depth), component.descr, component.view, static?}

    extra
    |> Compiler.components()
    |> Enum.map(fn component ->
      label = label(component, depth)
      tag_in_spec? = label == :structured and tag_in_spec?(component.view, spec_return)

      subtraction? =
        tag_in_spec? and subtraction_payload?(component, label, returns, spec_return)

      present? = not subtraction? and present?(component.descr, label, returns)

      %{
        descr_string: Compiler.to_string(component.descr),
        kind: component.kind,
        label: label,
        present_in_contributing?: present?,
        detail: detail(component.view),
        tag_in_spec?: tag_in_spec?,
        subtraction_payload?: subtraction?,
        payload_gradual?:
          present? and label == :structured and
            not present?(component.descr, label, for({_, _, _, true} = r <- returns, do: r))
      }
    end)
  end

  defp component_reasons(components) do
    [
      uncounted(components),
      unknown_count(components),
      tag_in_spec_count(components),
      subtraction_count(components),
      gradual_count(components)
    ]
    |> Enum.filter(& &1)
  end

  defp containment(relations, outcome),
    do: for(%{containment: ^outcome, index: index} <- relations.contributing, do: index)

  defp gradual_count(components) do
    case Enum.count(components, & &1.payload_gradual?) do
      0 -> false
      n -> {:payload_gradual, n}
    end
  end

  defp uncounted(components) do
    case Enum.count(components, &(&1.label != :unknown and not &1.present_in_contributing?)) do
      0 -> false
      n -> {:not_in_contributing, n}
    end
  end

  defp subtraction_count(components) do
    case Enum.count(components, & &1.subtraction_payload?) do
      0 -> false
      n -> {:subtraction_payload, n}
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
    same = for {^label, return, _view, _static?} <- returns, do: return
    same != [] and Compiler.subtype?(descr, Compiler.union_all(same))
  end

  # DESIGN 3.1 step 5 for payloads: the component's structure beyond its tag
  # was created by subtracting the spec when every contributing return
  # component with the same label that it overlaps is `term()` somewhere the
  # component is narrower, and the component is outside the spec only
  # because of those positions: with each of them widened back to the
  # witness's `term()`, every piece of the component meets `S_hi`. A piece
  # that stays disjoint from the spec (`{:ok, pid(), :b}` from a clause
  # returning `{:ok, term(), :a or :b}` under a spec `{:ok, pid(), :a}`)
  # carries structure inference derived from the code, so the component
  # still counts. Only same-label components can witness presence (see
  # present?/3), so only they are consulted.
  defp subtraction_payload?(component, label, returns, spec_return) do
    witnesses =
      for {^label, descr, view, _static?} <- returns,
          not Compiler.disjoint?(component.descr, descr),
          do: view

    witnesses != [] and
      Enum.all?(witnesses, &narrowed_top?(component.view, &1, @subtraction_depth)) and
      Enum.any?(witnesses, fn witness ->
        component.descr
        |> pieces(component.view, witness, @subtraction_depth)
        |> Enum.all?(&(not Compiler.disjoint?(&1, spec_return)))
      end)
  end

  # The component split into pieces along the tuple positions where the
  # witness is not `term()` (one piece per combination of their components,
  # to the same depth as narrowed_top?/3), with every position where the
  # witness is `term()` widened to `term()`. Maps, and splits with more than
  # @max_pieces pieces, are not split: their single piece is `term()`, which
  # keeps the component a subtraction artefact (the reading before the
  # widening check).
  @max_pieces 64

  defp pieces(_descr, {:tuple, :closed, elements}, {:tuple, :closed, returned}, depth)
       when length(elements) == length(returned) do
    options = Enum.zip_with(elements, returned, &element_pieces(&1, &2, depth))

    if Enum.reduce(options, 1, &(length(&1) * &2)) > @max_pieces do
      [Compiler.term()]
    else
      options |> product() |> Enum.map(&Compiler.tuple/1)
    end
  end

  defp pieces(_descr, {:map, _tag, _fields, _domains}, _witness, _depth), do: [Compiler.term()]
  defp pieces(descr, _view, _witness, _depth), do: [descr]

  defp element_pieces(element, return, depth) do
    cond do
      top?(return) ->
        [Compiler.term()]

      depth == 0 ->
        [element]

      true ->
        returned = Compiler.components(return)

        Enum.flat_map(Compiler.components(element), fn component ->
          case Enum.reject(returned, &Compiler.disjoint?(component.descr, &1.descr)) do
            [] -> [component.descr]
            overlapping -> Enum.flat_map(overlapping, &pieces_of(component, &1, depth))
          end
        end)
    end
  end

  defp pieces_of(component, witness, depth),
    do: pieces(component.descr, component.view, witness.view, depth - 1)

  defp product([]), do: [[]]

  defp product([options | rest]) do
    tails = product(rest)
    for option <- options, tail <- tails, do: [option | tail]
  end

  defp narrowed_top?({:tuple, :closed, elements}, {:tuple, :closed, returned}, depth)
       when length(elements) == length(returned) do
    elements
    |> Enum.zip(returned)
    |> Enum.any?(fn {element, return} -> narrowed_element?(element, return, depth) end)
  end

  defp narrowed_top?({:map, _tag, fields, _domains}, {:map, _rtag, returned, _rdomains}, depth) do
    Enum.any?(fields, fn {key, value, _optional?} ->
      case List.keyfind(returned, key, 0) do
        {^key, return, _} -> narrowed_element?(value, return, depth)
        nil -> false
      end
    end)
  end

  defp narrowed_top?(_view, _returned, _depth), do: false

  defp narrowed_element?(element, return, depth) do
    cond do
      top?(return) ->
        not top?(element)

      depth == 0 ->
        false

      true ->
        returned = Compiler.components(return)

        element
        |> Compiler.components()
        |> Enum.any?(fn component ->
          overlapping = Enum.reject(returned, &Compiler.disjoint?(component.descr, &1.descr))

          overlapping != [] and
            Enum.all?(overlapping, &narrowed_top?(component.view, &1.view, depth - 1))
        end)
    end
  end

  defp top?(descr), do: Compiler.subtype?(Compiler.term(), descr)

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
