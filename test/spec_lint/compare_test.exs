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

    test "unsupported slices pass through" do
      result =
        Compare.function(
          [{:unsupported, :why}, {:ok, exact_slice([C.atom()], C.atom())}],
          [{[C.term()], C.atom()}],
          1
        )

      assert [{:unsupported, :why}, {:ok, %{overlap?: false}}] = result.slices
    end

    test "cutoff above max_clauses collapses to dynamic()" do
      clauses = for _ <- 0..C.max_clauses(), do: {[C.term()], C.atom([:a])}
      rel = Compare.slice(exact_slice([C.term()], C.atom()), clauses)
      assert rel.cutoff?
      assert rel.top_only?
    end
  end
end
