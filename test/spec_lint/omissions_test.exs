defmodule SpecLint.OmissionsTest do
  @moduledoc """
  Records the current SL002 evidence class of the nine real omissions of
  EXPERIMENTS.md "Real omissions found", reproduced in isolation by
  `SpecLint.OmissionFixtures.Cases` (see bench/corpus/omissions/README.md).

  Every fixture is a real omission (the spec omits a value the body can
  return for an in-spec input), so the DESIRED class is always one that
  warns: `clause_conflict` (gated) or `structured_possible`. None is reached
  today: gating recall on these is 0 of 9. The assertions pin the CURRENT
  class so that any future change to the classifier is visible; when one of
  them starts failing because the class improved, update the expected value
  and the tables in bench/corpus/omissions/README.md and STATUS.md.
  """

  use ExUnit.Case, async: true

  import SpecLint.TestHelpers

  alias SpecLint.{Analysis, Compiler, Evidence}
  alias SpecLint.OmissionFixtures.{Cases, Changeset, Conn, Num}

  # {fixture, original MFA, current class, current class with
  #  require_static_return: true, top_only reason?, desired class}
  @omissions [
    # Decimal.compare/2: the error/4 macro expands to dynamic(), so the union
    # is top-only. Desired: clause_conflict (the NaN clauses return the struct).
    {{:compare, 2}, "Decimal.compare/2", :unknown, :unknown, true, :clause_conflict},
    # Decimal.cmp/2: the same, by delegation to compare/2.
    {{:cmp, 2}, "Decimal.cmp/2", :unknown, :unknown, true, :clause_conflict},
    # Plug.Conn.Query.decode/4: Map.new/1 of a keyword gives atom keys, the
    # spec argument is too wide. Top-only. Desired: structured_possible.
    {{:decode, 2}, "Plug.Conn.Query.decode/4", :unknown, :unknown, true, :structured_possible},
    # Plug.Conn.merge_private/2: struct minus struct negation component, no
    # counted component. Desired: structured_possible.
    {{:merge_private, 2}, "Plug.Conn.merge_private/2", :unknown, :unknown, false,
     :structured_possible},
    # Ecto.Changeset.apply_action/2: {:ok, nil}; the only evidence is a
    # subtraction payload (F1). Desired: structured_possible.
    {{:apply_action, 2}, "Ecto.Changeset.apply_action/2", :unknown, :unknown, false,
     :structured_possible},
    # Ecto.Query.Builder.Join.escape/3: stale spec, 5-tuples for 4. The
    # clauses escape the spec domain (unguarded parameters). Desired:
    # clause_conflict.
    {{:join_escape, 3}, "Ecto.Query.Builder.Join.escape/3", :possible_domain_escape,
     :possible_domain_escape, true, :clause_conflict},
    # Ecto.Query.Builder.quoted_type/2: stale spec (:atom, {:tuple, _}, as
    # pairs). Clauses escape the domain. Desired: clause_conflict.
    {{:quoted_type, 2}, "Ecto.Query.Builder.quoted_type/2", :possible_domain_escape,
     :possible_domain_escape, false, :clause_conflict},
    # Ecto.Repo.Assoc.query/4: Enum.map with a spec'd fun, top-only.
    # Desired: structured_possible.
    {{:assoc_query, 4}, "Ecto.Repo.Assoc.query/4", :unknown, :unknown, true,
     :structured_possible},
    # Ecto.Repo.Preloader.query/7: Enum.map with an untyped fun, top-only.
    # Desired: structured_possible.
    {{:preloader_query, 7}, "Ecto.Repo.Preloader.query/7", :unknown, :unknown, true,
     :structured_possible}
  ]

  @warning_classes [:clause_conflict, :structured_possible]

  setup_all do
    result = Analysis.module(beam_path(Cases))
    assert result.status == :ok
    %{functions: Map.new(result.functions, &{&1.mfa, &1})}
  end

  for {{name, arity}, original, current, current_static, top_only?, desired} <- @omissions do
    @fixture {Cases, name, arity}
    @current current
    @current_static current_static
    @top_only top_only?
    @desired desired

    test "#{name}/#{arity} (#{original}) is currently #{current}", %{functions: functions} do
      function = Map.fetch!(functions, @fixture)
      assert function.status == :compared

      assert Evidence.classify_function(function.slices) == @current

      assert Evidence.classify_function(function.slices, require_static_return: true) ==
               @current_static

      assert Enum.any?(function.slices, fn slice ->
               :top_only in Evidence.classify(slice.relations).reasons
             end) == @top_only

      # Ground truth: this is a real omission, so a warning class is desired.
      assert @desired in @warning_classes
      refute @current in @warning_classes
    end
  end

  test "every fixture function has a recorded class", %{functions: functions} do
    assert functions |> Map.keys() |> Enum.sort() ==
             @omissions
             |> Enum.map(fn {{name, arity}, _, _, _, _, _} -> {Cases, name, arity} end)
             |> Enum.sort()
  end

  test "gating recall on the nine omissions is 0 of 9 today", %{functions: functions} do
    gated =
      for {mfa, function} <- functions,
          Evidence.classify_function(function.slices) == :clause_conflict,
          do: mfa

    assert gated == []
  end

  test "all contributing inferred domains escape even the spec upper bound", %{
    functions: functions
  } do
    for {_mfa, function} <- functions, slice <- function.slices do
      lower = slice.args |> Enum.map(& &1.lo) |> Compiler.tuple()
      upper = slice.args |> Enum.map(& &1.hi) |> Compiler.tuple()
      assert Compiler.subtype?(lower, upper)
      assert slice.relations.contributing != []

      for clause <- slice.relations.contributing do
        inferred = clause.args |> Enum.map(&Compiler.upper_bound/1) |> Compiler.tuple()

        # Each clause still overlaps the spec domain, so this is a loss of
        # containment, not a fully disjoint clause that could be ignored.
        refute Compiler.disjoint?(inferred, upper)
        refute Compiler.subtype?(inferred, upper)
        refute Compiler.subtype?(inferred, lower)
      end
    end
  end

  describe "runtime witnesses for in-spec inputs and omitted returns" do
    test "compare/2 returns a Num for a NaN input" do
      Process.delete(:traps)
      nan = %Num{coef: :NaN}

      assert Cases.compare(nan, %Num{}) == nan
    end

    test "cmp/2 delegates the omitted NaN return" do
      Process.delete(:traps)
      nan = %Num{coef: :NaN}

      assert Cases.cmp(nan, %Num{}) == nan
    end

    test "decode/2 returns an atom key from a permitted keyword input" do
      assert Cases.decode("", unexpected: 1) == %{unexpected: 1}
    end

    test "merge_private/2 can put a binary key into the typed private map" do
      assert %Conn{private: %{"unexpected" => 1}} =
               Cases.merge_private(%Conn{}, [{"unexpected", 1}])
    end

    test "apply_action/2 can return nil inside the success tuple" do
      changeset = %Changeset{valid?: true, data: nil, changes: %{}}

      assert Cases.apply_action(changeset, :insert) == {:ok, nil}
    end

    test "join_escape/3 returns a five-tuple for a valid AST" do
      result = Cases.join_escape(:my_schema, [], __ENV__)

      assert is_tuple(result)
      assert tuple_size(result) == 5
    end

    test "quoted_type/2 returns the undeclared :atom primitive" do
      assert Cases.quoted_type(:example, []) == :atom
    end

    test "assoc_query/4 returns rows rather than structs" do
      rows = [[%{id: 1}]]
      result = Cases.assoc_query(rows, [], {}, fn row -> row end)

      assert result == rows
      refute is_struct(hd(result))
    end

    test "preloader_query/7 permits a function that returns a non-list" do
      assert Cases.preloader_query([[1]], nil, [], %{}, [], fn _ -> :unexpected end, {%{}, []}) ==
               [:unexpected]
    end
  end
end
