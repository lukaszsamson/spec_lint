defmodule SpecLint.ClauseMappingTest do
  # Milestone 4: the source clauses of stored signature clauses, adopted
  # only where compiler invariants decide them (SpecLint.ClauseMapping).
  use ExUnit.Case, async: true

  import SpecLint.TestHelpers

  alias SpecLint.{Analysis, Beam, ClauseMapping, Evidence, Issue, Policy}
  alias SpecLint.ClauseMappingFixtures, as: Fixtures
  alias SpecLint.Compiler, as: C
  alias SpecLint.Compiler.{V120, V121}
  alias SpecLint.OmissionFixtures.ClauseLocal, as: Omission
  alias SpecLint.Rules.ReturnConflict

  defp clause(line, meta \\ []), do: {[line: line] ++ meta, [], [], :ok}

  describe "map/3" do
    test "one source clause: every stored clause comes from it" do
      assert {:exact, :single, [[%{index: 0, line: 3, file: nil}]]} =
               ClauseMapping.map([clause(3)], 1)

      assert {:exact, :single, [[a], [a], [a]]} = ClauseMapping.map([clause(3)], 3)
      assert a == %{index: 0, line: 3, file: nil}
    end

    test "as many stored as source clauses: the identity" do
      assert {:exact, :identity, per_stored} =
               ClauseMapping.map([clause(3), clause(5), clause(9)], 3)

      assert Enum.map(per_stored, fn [c] -> {c.index, c.line} end) == [{0, 3}, {1, 5}, {2, 9}]
    end

    test "fewer stored clauses, more stored clauses, no clauses: ambiguous" do
      assert ClauseMapping.map([clause(3), clause(5), clause(9)], 2) ==
               {:ambiguous, :merged_or_dropped}

      assert ClauseMapping.map([clause(3), clause(5)], 1) == {:ambiguous, :merged_or_dropped}

      assert ClauseMapping.map([clause(3), clause(5)], 3) ==
               {:ambiguous, :more_stored_than_source}

      assert ClauseMapping.map([], 1) == {:ambiguous, :no_source_clauses}
    end

    test "lines and files: unknown lines stay unknown, another file is named" do
      mapping =
        ClauseMapping.map(
          [clause(nil), clause(4, file: {"/src/lib/a.ex", 4}), clause(7, file: {"/src/b.ex", 2})],
          3,
          "/src/lib/a.ex"
        )

      assert {:exact, :identity, [[first], [second], [third]]} = mapping
      assert ClauseMapping.text(first) == "#0, line unknown"
      assert ClauseMapping.text(second) == "#1, line 4"
      assert ClauseMapping.text(third) == "#2, line 7 of b.ex"
    end

    test "source_clause/2 and class/1" do
      mapping = ClauseMapping.map([clause(3), clause(5)], 2)
      assert {:ok, %{index: 1, line: 5}} = ClauseMapping.source_clause(mapping, 1)
      assert ClauseMapping.source_clause(mapping, 2) == :error
      assert ClauseMapping.class(mapping) == :identity

      ambiguous = ClauseMapping.map([clause(3), clause(5)], 1)
      assert ClauseMapping.source_clause(ambiguous, 0) == :error
      assert ClauseMapping.source_clause(nil, 0) == :error
      assert ClauseMapping.class(ambiguous) == :ambiguous
      assert ClauseMapping.class(nil) == :ambiguous
    end
  end

  # Expected mappings, written from the source and the pipeline
  # (SpecLint.ClauseMapping, "Invariants"): the stored clause count is the
  # compiler's, the mapping is then forced or ambiguous.
  @identity_3 {:identity, [[0], [1], [2]]}
  @expected %{
    {:single, 1} => {:single, [[0]]},
    {:with_default, 1} => {:single, [[0]]},
    {:with_default, 2} => @identity_3,
    {:guarded, 1} => {:identity, [[0], [1], [2], [3]]},
    {:merged, 1} => :ambiguous,
    {:all_raise, 1} => :ambiguous,
    {:redundant, 1} => @identity_3,
    {:many, 1} => {:identity, Enum.map(0..19, &[&1])},
    {:identity_conflict, 1} => {:identity, [[0], [1]]},
    {:ambiguous_conflict, 1} => :ambiguous
  }

  # A raising clause is dropped by 1.21 and stored as `-> none()` by
  # 1.20.4; the generated redundant clause of gen_red/1 merges on 1.21 only.
  @per_adapter %{
    V121 => %{{:raising, 1} => :ambiguous, {:gen_red, 1} => :ambiguous},
    V120 => %{{:raising, 1} => @identity_3, {:gen_red, 1} => @identity_3}
  }

  # The return atoms of each source clause, to check an exact mapping
  # against the stored returns (:none for a raising clause).
  @returns %{
    {:redundant, 1} => [:int, :never, :zed],
    {:raising, 1} => [:first, :none, :third],
    {:gen_red, 1} => [:user, :gen, :rest],
    {:many, 1} => Enum.map(0..19, &:"r#{&1}")
  }

  describe "fixtures" do
    setup do
      {:ok, beam} = Beam.read(beam_path(Fixtures))
      {:ok, info} = beam.debug_info
      {:ok, %{exports: exports}} = beam.exck

      mappings =
        for {fun_arity, :def, _meta, clauses} <- info.definitions,
            %{sig: {:infer, _domain, stored}} <- [Map.get(exports, fun_arity)],
            into: %{},
            do: {fun_arity, {ClauseMapping.map(clauses, length(stored), info.file), stored}}

      %{mappings: mappings}
    end

    test "every definition maps as expected under the running adapter", %{mappings: mappings} do
      expected = Map.merge(@expected, @per_adapter[C.running_adapter()])
      assert mappings |> Map.keys() |> Enum.sort() == expected |> Map.keys() |> Enum.sort()

      for {fun_arity, {mapping, _stored}} <- mappings do
        assert simplify(mapping) == expected[fun_arity], inspect(fun_arity)
      end
    end

    test "an exact mapping gives each stored clause its source clause's return",
         %{mappings: mappings} do
      checked =
        for {fun_arity, atoms} <- @returns,
            {{:exact, _class, per_stored}, stored} <- [mappings[fun_arity]] do
          for {[%{index: index}], {_args, return}} <- Enum.zip(per_stored, stored) do
            case Enum.at(atoms, index) do
              :none -> assert C.empty?(return)
              atom -> assert C.subtype?(C.atom([atom]), return), inspect({fun_arity, index})
            end
          end

          fun_arity
        end

      assert {:many, 1} in checked and {:redundant, 1} in checked
    end

    test "Analysis attaches the mapping to spec'd functions" do
      assert {:exact, :identity, [[_], [_]]} =
               analysed(Fixtures, :identity_conflict, 1).clause_mapping

      assert {:ambiguous, :merged_or_dropped} =
               analysed(Fixtures, :ambiguous_conflict, 1).clause_mapping
    end
  end

  describe "clause conflict details" do
    test "an identity mapping names the source clause and its line" do
      assert [issue] = ReturnConflict.check_function(rule_context(Fixtures, :identity_conflict))
      assert %Issue{evidence: :clause_conflict, clause: 1} = issue
      line = clause_line(Fixtures, {:identity_conflict, 1}, 1)
      assert {"source clause", "#1, line #{line}"} in issue.details
      assert issue.data.source_clause == %{index: 1, line: line, file: nil}
      assert issue.data.clause_mapping == :identity
    end

    test "an ambiguous mapping says so and carries no source clause" do
      assert [issue] = ReturnConflict.check_function(rule_context(Fixtures, :ambiguous_conflict))
      assert %Issue{evidence: :clause_conflict, clause: 1} = issue

      assert {"source clause", "not determined (the compiler may have merged or dropped clauses)"} in issue.details

      assert issue.data.clause_mapping == :ambiguous
      refute Map.has_key?(issue.data, :source_clause)
    end

    test "the mapping changes no prerequisite, gate or fingerprint" do
      for name <- [:identity_conflict, :ambiguous_conflict] do
        context = rule_context(Fixtures, name)
        [with_mapping] = ReturnConflict.check_function(context)

        [without] =
          ReturnConflict.check_function(put_in(context.function.clause_mapping, nil))

        assert {"source clause", "not determined (no debug info for the definition)"} in without.details
        assert with_mapping.prerequisites == without.prerequisites
        assert with_mapping.fingerprint == without.fingerprint

        assert Policy.gate?(with_mapping, %SpecLint.Config{}) ==
                 Policy.gate?(without, %SpecLint.Config{})
      end
    end

    test "a pattern diagnostic on another clause still blocks the whole function" do
      context =
        rule_context(
          Fixtures,
          :identity_conflict,
          {:ok, [clause_line(Fixtures, {:identity_conflict, 1}, 0)]}
        )

      assert [issue] = ReturnConflict.check_function(context)
      assert {:clause_reachable, :blocked} in issue.prerequisites
    end

    test "the witnessed stand-ins name their source clauses" do
      assert [page_opts] = ReturnConflict.check_function(rule_context(Omission, :page_opts))
      line = clause_line(Omission, {:page_opts, 1}, 0)
      assert {"source clause", "#0, line #{line}"} in page_opts.details

      assert [via] = ReturnConflict.check_function(rule_context(Omission, :via))
      line = clause_line(Omission, {:via, 3}, 1)
      assert {"source clause", "#1, line #{line}"} in via.details
    end
  end

  defp simplify({:exact, class, per_stored}),
    do: {class, Enum.map(per_stored, fn clauses -> Enum.map(clauses, & &1.index) end)}

  defp simplify({:ambiguous, _reason}), do: :ambiguous

  defp clause_line(module, fun_arity, index) do
    {:ok, beam} = Beam.read(beam_path(module))
    {:ok, info} = beam.debug_info
    {^fun_arity, :def, _meta, clauses} = List.keyfind(info.definitions, fun_arity, 0)
    {meta, _args, _guards, _body} = Enum.at(clauses, index)
    Keyword.fetch!(meta, :line)
  end

  defp rule_context(module, name, check \\ {:ok, []}) do
    result = Analysis.module(beam_path(module))
    function = Enum.find(result.functions, &match?({^module, ^name, _}, &1.mfa))

    slices =
      for slice <- function.slices do
        %{slice: slice, evidence: slice.relations && Evidence.classify(slice.relations)}
      end

    %{
      module: result,
      function: function,
      file: nil,
      slices: slices,
      severity: :warning,
      clause_local_qualification: true,
      pattern_diagnostics: check
    }
  end
end
