defmodule SpecLint.CompareTest do
  use ExUnit.Case, async: true

  import SpecLint.TestHelpers

  alias SpecLint.{Bound, Compare}
  alias SpecLint.Compiler, as: C
  alias SpecLint.Fixtures.Compare, as: F

  defp exact_slice(args, ret),
    do: %{args: Enum.map(args, &Bound.exact/1), return: Bound.exact(ret)}

  defp relations(name, arity, index \\ 0) do
    function = analysed(F, name, arity)
    assert function.status == :compared
    Enum.at(function.slices, index).relations
  end

  test "disjoint return" do
    rel = relations(:disjoint, 1)
    assert rel.return_relation == :disjoint
    assert C.equal?(rel.applied_upper, C.integer())
    assert C.equal?(rel.extra, C.integer())
    assert C.equal?(rel.missing, C.atom())
    refute rel.badapply?
    assert [%{index: 0, containment: :contained, static_return?: false}] = rel.contributing
  end

  test "tagged-tuple extra with contained domain" do
    rel = relations(:lookup, 1)
    assert C.equal?(rel.extra, C.tuple([C.atom([:error]), C.atom([:missing])]))
    assert rel.return_relation == :superset
    refute rel.input_approximate?
    refute rel.top_only?
    assert Enum.map(rel.contributing, & &1.containment) == [:contained, :contained]
    assert Enum.all?(rel.contributing, & &1.static_return?)
    assert rel.applied == {:ok, [0, 1]}
    assert rel.domain_relation == [:equal]
  end

  test "incomparable domains yield domain_escape" do
    rel = relations(:incomparable, 1)
    assert [%{containment: :domain_escape}] = rel.contributing
    assert rel.domain_relation == [:overlapping]
    assert rel.domain_overlap?
    assert C.empty?(rel.extra)
  end

  test "pos_integer() input approximation is flagged" do
    rel = relations(:classify, 1)
    assert rel.input_approximate?
    assert C.equal?(rel.extra, C.atom([:nonpositive]))
    # Every clause is contained in integer() = D_hi, but D_hi is wider than
    # the spec domain, so containment cannot be decided.
    assert [%{containment: :containment_unknown}] = rel.contributing
  end

  test "no_return() spec with a non-empty applied return" do
    rel = relations(:halt, 1)
    assert rel.spec_return_empty?
    refute C.empty?(rel.applied_upper)
    assert C.equal?(rel.extra, rel.applied_upper)
    assert rel.return_relation == :empty
  end

  test "badapply when no inferred clause accepts the spec domain" do
    rel = relations(:rejected, 1)
    assert rel.badapply?
    assert rel.applied == :badapply
    assert rel.contributing == []
    assert C.empty?(rel.applied_upper)
    assert rel.domain_relation == [:disjoint]
    refute rel.domain_overlap?
    # A rejected domain never establishes the obligation, although none()
    # is a subtype of every spec return.
    refute rel.established?
  end

  test "a type variable in a callback argument is not a domain escape" do
    # apply_to({a}, (a -> term())): the inferred callback domain is fun(1).
    # Translating the callback as (term() -> term()) excluded instances such
    # as (integer() -> term()) from D_hi and reported a certain escape.
    rel = relations(:apply_to, 2)
    assert rel.input_approximate?
    assert [%{containment: :containment_unknown}] = rel.contributing
  end

  test "a clause inside D_lo is contained even when the slice is approximate" do
    loss = Bound.loss(:integer_refinement_erased, [])

    slice = %{
      args: [%Bound{lo: C.integer(), hi: C.term(), losses: [loss]}],
      return: Bound.exact(C.atom([:ok]))
    }

    contained = Compare.slice(slice, [{[C.integer()], C.atom([:ok])}])
    assert contained.input_approximate?
    assert [%{containment: :contained}] = contained.contributing

    unknown = Compare.slice(slice, [{[C.atom()], C.atom([:ok])}])
    assert [%{containment: :containment_unknown}] = unknown.contributing
  end

  test "overlapping overloads are tagged" do
    function = analysed(F, :overloaded, 1)
    assert [first, second] = function.slices
    assert first.relations.overlap?
    assert first.relations.overlaps_with == [1]
    assert second.relations.overlaps_with == [0]
  end

  test "exact match is established" do
    rel = relations(:exact_match, 1)
    assert rel.return_relation == :equal
    assert rel.established?
    assert C.empty?(rel.extra)
    assert C.empty?(rel.missing)
  end

  test "top-only inference is recognised" do
    rel = relations(:private_caller, 1)
    assert rel.top_only?
  end

  test "all-dynamic probe" do
    function = analysed(F, :lookup, 1)

    assert %{relation: :superset, applied: {:ok, [0, 1]}} = function.dynamic_probe

    assert C.equal?(
             function.dynamic_probe.return,
             C.union(
               C.tuple([C.atom([:ok]), C.integer()]),
               C.tuple([C.atom([:error]), C.atom([:missing])])
             )
           )

    assert %{relation: :badapply} = Compare.dynamic_probe([], 1, [C.atom()])
  end

  describe "pure relations" do
    test "applied return is dynamic-wrapped; stored precision is per clause" do
      clauses = [{[C.integer()], C.atom([:a])}, {[C.atom()], C.dynamic(C.binary())}]
      rel = Compare.slice(exact_slice([C.integer()], C.atom([:a])), clauses)
      assert C.gradual?(rel.applied_return)
      assert [%{index: 0, static_return?: true}] = rel.contributing
      assert rel.return_relation == :equal

      rel = Compare.slice(exact_slice([C.atom()], C.binary()), clauses)
      assert [%{index: 1, static_return?: false}] = rel.contributing
    end

    test "containment is decided tuple-wise" do
      # Spec (:a, 1-ish) | ... as one product slice; the clause domain
      # {atom(), integer()} escapes the spec product {:a, integer()}.
      clauses = [{[C.atom(), C.integer()], C.atom([:ok])}]
      rel = Compare.slice(exact_slice([C.atom([:a]), C.integer()], C.atom([:ok])), clauses)
      assert [%{containment: :domain_escape}] = rel.contributing

      rel = Compare.slice(exact_slice([C.atom(), C.integer()], C.atom([:ok])), clauses)
      assert [%{containment: :contained}] = rel.contributing
    end

    test "clauses covered by the clauses before them are possibly shadowed" do
      # The g/1 shape: def g(a) when is_atom(a); def g(:x). The compiler
      # reports (:x) as redundant; the stored domains show it.
      clauses = [
        {[C.atom()], C.atom([:ok])},
        {[C.atom([:x])], C.atom([:error])},
        {[C.integer()], C.atom([:ok])},
        {[C.union(C.atom([:y]), C.integer())], C.atom([:error])},
        {[C.binary()], C.atom([:ok])}
      ]

      assert Compare.shadowed(clauses) == [1, 3]
      assert Compare.shadowed([]) == []
      assert Compare.shadowed([{[C.atom([:x])], C.atom([:ok])}]) == []

      rel = Compare.slice(exact_slice([C.atom()], C.atom([:ok])), clauses)

      assert Enum.map(rel.contributing, &{&1.index, &1.shadowed?}) == [
               {0, false},
               {1, true},
               {3, true}
             ]

      # Covered only by the union of two earlier clauses, per tuple.
      pairs = [
        {[C.atom(), C.integer()], C.atom([:ok])},
        {[C.integer(), C.integer()], C.atom([:ok])},
        {[C.union(C.atom(), C.integer()), C.integer()], C.atom([:error])},
        {[C.union(C.atom(), C.integer()), C.atom()], C.atom([:error])}
      ]

      assert Compare.shadowed(pairs) == [2]
    end

    test "unsupported slices pass through" do
      result =
        Compare.function(
          [{:unsupported, :why}, {:ok, exact_slice([C.atom()], C.atom())}],
          [{[C.term()], C.atom()}],
          1
        )

      assert [{:unsupported, :why}, {:ok, %{overlap?: false}}] = result.slices
    end

    test "an unsupported sibling makes overlap unknown unless shown disjoint" do
      atom_slice = exact_slice([C.atom()], C.integer())
      clauses = [{[C.atom()], C.atom()}]

      # No argument bounds: the sibling was never interpreted.
      %{slices: [{:ok, rel}, {:unsupported, :why}]} =
        Compare.function([{:ok, atom_slice}, {:unsupported, :why}], clauses, 1)

      refute rel.overlap?
      assert rel.overlap_unknown?
      assert rel.overlaps_unknown_with == [1]

      # Argument upper bounds that meet the slice's domain: still unknown,
      # never a certain overlap.
      term = Bound.upper(C.term(), :unsupported_construct, [{:arg, 0}])

      for bounds <- [[term], [Bound.exact(C.atom([:a]))]] do
        %{slices: [{:ok, rel}, {:unsupported, :why}]} =
          Compare.function([{:ok, atom_slice}, {:unsupported, :why, bounds}], clauses, 1)

        refute rel.overlap?
        assert rel.overlaps_unknown_with == [1]
      end

      # Upper bounds disjoint from the slice's domain: no overlap.
      %{slices: [{:ok, rel}, _]} =
        Compare.function(
          [{:ok, atom_slice}, {:unsupported, :why, [Bound.exact(C.integer())]}],
          clauses,
          1
        )

      refute rel.overlap?
      refute rel.overlap_unknown?

      # The sibling comes first: same tag on the supported slice.
      %{slices: [{:unsupported, :why}, {:ok, rel}]} =
        Compare.function([{:unsupported, :why}, {:ok, atom_slice}], clauses, 1)

      assert rel.overlaps_unknown_with == [0]
    end

    test "an unsupported sibling is disjoint through any one translated position" do
      slice = exact_slice([C.atom(), C.integer()], C.atom())
      clauses = [{[C.atom(), C.integer()], C.atom()}]
      unknown = Bound.upper(C.term(), :unsupported_construct, [{:arg, 0}])

      # Position 0 is untranslatable (term()), position 1 is atom(): disjoint.
      %{slices: [{:ok, rel}, _]} =
        Compare.function(
          [{:ok, slice}, {:unsupported, :why, [unknown, Bound.exact(C.atom())]}],
          clauses,
          2
        )

      refute rel.overlap_unknown?

      # Disjoint integer intervals at position 1 (0 against pos_integer()).
      pos = %Bound{
        lo: C.none(),
        hi: C.integer(),
        losses: [Bound.loss(:integer_refinement_erased, [{:arg, 1}])],
        integers: [{1, :infinity}]
      }

      zero = %{pos | integers: [{0, 0}]}
      refined = %{args: [Bound.exact(C.atom()), zero], return: Bound.exact(C.atom())}

      %{slices: [{:ok, rel}, _]} =
        Compare.function([{:ok, refined}, {:unsupported, :why, [unknown, pos]}], clauses, 2)

      refute rel.overlap_unknown?

      # Both positions meet: unknown.
      %{slices: [{:ok, rel}, _]} =
        Compare.function(
          [{:ok, slice}, {:unsupported, :why, [unknown, Bound.exact(C.term())]}],
          clauses,
          2
        )

      assert rel.overlaps_unknown_with == [1]
    end

    test "analysis passes an unsupported sibling's argument bounds to the overlap tag" do
      alias SpecLint.Fixtures.Siblings
      result = seeded_analysis(Siblings)
      by_name = Map.new(result.functions, &{elem(&1.mfa, 1), &1})

      # The sibling's only argument is untranslatable: overlap unknown.
      assert [first, %{status: {:unsupported, _}}] = by_name.unsupported_sibling.slices
      assert first.relations.overlaps_unknown_with == [1]
      refute first.relations.overlap?

      # The sibling's argument integer() translates and is disjoint.
      assert [first, %{status: {:unsupported, _}}] = by_name.disjoint_sibling.slices
      refute first.relations.overlap_unknown?
      refute first.relations.overlap?
    end

    test "integer literals and ranges do not create false overlap tags (O5)" do
      # Macro.generate_unique_arguments/2: (0, atom()) and (pos_integer(), atom())
      # both erase to (integer(), atom()) but are disjoint.
      function = analysed(F, :unique_args, 2)

      for slice <- function.slices do
        refute slice.relations.overlap?
        refute slice.relations.overlap_unknown?
      end

      # (1..3 | -1, atom()), (4..10, atom()) and (non_neg_integer(), :x):
      # the first two are disjoint; each meets the third, but the lower
      # bounds cannot show it, so that overlap is unknown, not certain.
      assert [first, second, third] = analysed(F, :ranges, 2).slices
      assert first.relations.overlaps_with == []
      assert first.relations.overlaps_unknown_with == [2]
      assert second.relations.overlaps_unknown_with == [2]
      assert third.relations.overlaps_unknown_with == [0, 1]
      refute third.relations.overlap?
    end

    test "near-top returns" do
      keyword = C.list(C.tuple([C.atom(), C.term()]))
      assert Compare.near_top?(C.dynamic(C.difference(C.term(), C.atom([:undefined]))), keyword)
      assert Compare.near_top?(C.difference(C.term(), C.atom([false, nil])), keyword)
      assert Compare.near_top?(C.dynamic(C.difference(C.term(), C.empty_list())), keyword)
      assert Compare.near_top?(C.term(), keyword)
      # term() minus all atoms leaves pid, port, reference and fun whole.
      assert Compare.near_top?(C.difference(C.term(), C.atom()), C.atom())
      refute Compare.near_top?(C.union_all([C.pid(), C.port(), C.reference()]), keyword)
      refute Compare.near_top?(C.union(C.fun(), C.pid()), C.union(C.fun(), C.pid()))
      refute Compare.near_top?(C.union(C.integer(), C.binary()), keyword)
      refute Compare.near_top?(C.none(), keyword)

      rel = Compare.slice(exact_slice([C.atom()], keyword), [{[C.atom()], C.dynamic()}])
      assert rel.top_only?
      refute rel.near_top?
    end

    test "cutoff above max_clauses collapses to dynamic()" do
      clauses = for _ <- 0..C.max_clauses(), do: {[C.term()], C.atom([:a])}
      rel = Compare.slice(exact_slice([C.term()], C.atom()), clauses)
      assert rel.cutoff?
      assert rel.top_only?
    end
  end
end
