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

  alias SpecLint.{Analysis, Evidence}
  alias SpecLint.OmissionFixtures.Cases

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
end
