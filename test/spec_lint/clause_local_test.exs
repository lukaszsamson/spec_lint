defmodule SpecLint.ClauseLocalTest do
  @moduledoc """
  The clause-local qualification experiment (`clause_local_qualification`,
  `SpecLint.Rules.ReturnConflict`, bench/corpus/clause_local_qualification.md).

  With the flag, an SL001 clause conflict needs its clause's whole domain
  contained in the spec's argument lower bounds instead of the slice-wide
  arrow prerequisites. The positive stand-ins are
  `SpecLint.OmissionFixtures.ClauseLocal` (Ash.Page.page_opts/1 and
  Oban.Registry.via/3, pinned in test/spec_lint/omissions_test.exs); the
  controls are `SpecLint.Fixtures.ClauseLocal`.
  """

  use ExUnit.Case, async: true

  import SpecLint.TestHelpers

  alias SpecLint.{Analysis, Baseline, CLI, Compiler, Config, Issue, Policy, Project, Run}
  alias SpecLint.Fixtures.{ClauseLocal, Review}
  alias SpecLint.OmissionFixtures.ClauseLocal, as: Omission
  alias SpecLint.Report.Json

  @moduletag :tmp_dir

  @off %Config{baseline: "tmp/none.json"}
  @on %Config{baseline: "tmp/none.json", clause_local_qualification: true}

  setup_all do
    %{
      off: run!([ClauseLocal, Omission, Review], [], @off),
      on: run!([ClauseLocal, Omission, Review], [], @on)
    }
  end

  defp sl001(run, mfa), do: run |> issues(mfa) |> Enum.filter(&(&1.rule == "SL001"))

  describe "configuration" do
    test "defaults to off, is validated, and is overridden by the command line" do
      refute %Config{}.clause_local_qualification

      assert {:ok, %Config{clause_local_qualification: true}} =
               Config.from_keyword(clause_local_qualification: true)

      assert {:error, message} = Config.from_keyword(clause_local_qualification: :yes)
      assert message =~ "invalid value for :clause_local_qualification"

      assert {:ok, cli} = CLI.parse(["--clause-local-qualification"])
      assert cli.clause_local_qualification
      assert {:ok, config} = Config.merge_cli(%Config{}, CLI.config_overrides(cli))
      assert config.clause_local_qualification

      assert {:ok, cli} = CLI.parse([])
      assert {:ok, config} = Config.merge_cli(%Config{}, CLI.config_overrides(cli))
      refute config.clause_local_qualification
      refute Config.digest(%Config{}) == Config.digest(%Config{clause_local_qualification: true})
    end

    test "the JSON report records the setting", %{off: off, on: on} do
      for {run, value} <- [{off, false}, {on, true}] do
        json = run |> Json.envelope() |> Json.encode() |> IO.iodata_to_binary()
        assert JSON.decode!(json)["config"]["clause_local_qualification"] == value
      end
    end
  end

  describe "Compare: containment of the whole clause domain in D_lo" do
    test "the literal clause of page_opts/1 is contained, the catch-all is not" do
      [slice] = analysed(Omission, :page_opts, 1).slices
      assert [c0, c1] = slice.relations.contributing
      assert %{index: 0, containment: :contained, contained_lo?: true} = c0
      assert %{index: 1, containment: :domain_escape, contained_lo?: false} = c1

      # The arrow is inside the struct: D_lo keeps the struct with rerun: nil,
      # D_hi adds the functions, and nothing else differs.
      [arg] = slice.args
      assert :arrow_polarity in SpecLint.Bound.loss_kinds(arg)
      refute Compiler.empty?(arg.lo)
      assert Compiler.subtype?(arg.lo, arg.hi)
    end

    test "a clause inside D_hi only, or escaping an empty D_lo, is not contained" do
      [slice] = analysed(ClauseLocal, :only_hi, 1).slices
      integer_clause = Enum.find(slice.relations.contributing, &(&1.index == 1))
      assert %{containment: :containment_unknown, contained_lo?: false} = integer_clause

      [slice] = analysed(ClauseLocal, :impossible, 1).slices
      assert slice.args |> Enum.map(& &1.lo) |> Compiler.tuple() |> Compiler.empty?()
      refute Enum.any?(slice.relations.contributing, & &1.contained_lo?)
      assert Enum.any?(slice.relations.contributing, &(&1.containment == :domain_escape))
    end

    test "an exact slice: contained_lo? is containment itself" do
      [slice] = analysed(Omission, :via, 3).slices
      assert Enum.all?(slice.args, &SpecLint.Bound.exact?/1)

      for clause <- slice.relations.contributing do
        assert clause.contained_lo? == (clause.containment == :contained)
      end
    end
  end

  describe "positive stand-ins" do
    test "page_opts/1 is blocked by the arrow argument without the flag and gates with it",
         %{off: off, on: on} do
      mfa = {Omission, :page_opts, 1}
      assert [before] = sl001(off, mfa)
      assert %Issue{evidence: :clause_conflict, slice: 0, clause: 0, gate: false} = before
      assert Issue.blocked(before) == [:no_arrow_polarity_argument]
      assert before.data == %{}

      assert [after_] = sl001(on, mfa)
      assert %Issue{evidence: :clause_conflict, slice: 0, clause: 0, gate: true} = after_

      assert after_.prerequisites == [
               no_unsupported_loss: :met,
               no_overlap: :met,
               clause_contained_in_lo: :met,
               clause_reachable: :unchecked
             ]

      assert after_.data == %{
               qualification: :clause_local,
               superseded_prerequisites: [
                 [:no_arrow_in_return, :met],
                 [:no_arrow_polarity_argument, :blocked]
               ]
             }

      assert Policy.explain(after_, @on) =~ "gates"

      assert Enum.find_value(after_.details, &(elem(&1, 0) == "evidence" && elem(&1, 1))) =~
               "clause contained in the spec lower bound"

      # The fingerprint does not depend on the setting, so a baseline entry
      # written while it was blocked is a gate change, not an acknowledgement.
      assert after_.fingerprint == before.fingerprint
    end

    test "via/3 gates with and without the flag", %{off: off, on: on} do
      mfa = {Omission, :via, 3}

      assert [%Issue{evidence: :clause_conflict, clause: 1, gate: true} = before] =
               sl001(off, mfa)

      assert [%Issue{evidence: :clause_conflict, clause: 1, gate: true} = after_] = sl001(on, mfa)
      assert Issue.blocked(before) == []
      assert {:clause_contained_in_lo, :met} in after_.prerequisites
      assert after_.fingerprint == before.fingerprint
    end

    test "a function returned at another arity than the arrow return gates with the flag",
         %{off: off, on: on} do
      mfa = {ClauseLocal, :other_arity, 1}
      assert [before] = sl001(off, mfa)
      assert %Issue{evidence: :clause_conflict, clause: 1, gate: false} = before
      assert Issue.blocked(before) == [:no_arrow_in_return]

      assert [%Issue{evidence: :clause_conflict, clause: 1, gate: true}] = sl001(on, mfa)

      # Runtime: the in-spec input :b returns a 2-ary function; no value of
      # (pos_integer() -> atom()) is one. Control: :a returns a 1-ary one.
      assert is_function(ClauseLocal.other_arity(:b), 2)
      refute is_function(ClauseLocal.other_arity(:b), 1)
      assert is_function(ClauseLocal.other_arity(:a), 1)
    end
  end

  describe "negative controls never gate" do
    test "a clause contained only in D_hi is no clause conflict", %{off: off, on: on} do
      for run <- [off, on], do: assert(sl001(run, {ClauseLocal, :only_hi, 1}) == [])
    end

    test "overlapping overloads stay blocked by the overlap tag", %{on: on} do
      issues = sl001(on, {ClauseLocal, :overlapping, 1})
      assert [%{slice: 0}, %{slice: 1}] = issues

      for issue <- issues do
        assert issue.evidence == :clause_conflict
        assert Issue.blocked(issue) == [:no_overlap]
        refute issue.gate
      end
    end

    test "an impossible input (empty D_lo, escaping clause) yields no SL001", %{off: off, on: on} do
      for run <- [off, on], do: assert(sl001(run, {ClauseLocal, :impossible, 1}) == [])
    end

    test "a function returned under an inexact arrow return is not disjoint", %{on: on} do
      assert sl001(on, {ClauseLocal, :same_arity, 1}) == []
      assert is_function(ClauseLocal.same_arity(:a), 1)
    end

    test "gradual top-only and near-top clause returns are no evidence", %{on: on} do
      assert sl001(on, {ClauseLocal, :gradual, 1}) == []
      assert sl001(on, {ClauseLocal, :near_top, 1}) == []
    end

    test "a redundant clause stays blocked by reachability", %{on: on} do
      assert [issue] = sl001(on, {ClauseLocal, :redundant, 1})
      assert %Issue{evidence: :clause_conflict, clause: 1, gate: false} = issue
      assert Issue.blocked(issue) == [:clause_reachable]
      assert {:clause_contained_in_lo, :met} in issue.prerequisites
    end

    test "the slice-level form keeps the slice-wide arrow prerequisite", %{on: on} do
      assert [issue] = sl001(on, {Review, :apply_it, 2})
      assert %Issue{evidence: :conflict, gate: false} = issue
      assert {:no_arrow_polarity_argument, :blocked} in issue.prerequisites
      refute Keyword.has_key?(issue.prerequisites, :clause_contained_in_lo)
    end

    test "with require_static_return the gradual page_opts/1 clause is not a conflict" do
      config = %{@on | require_static_return: true}
      run = run!([Omission], [], config)
      assert sl001(run, {Omission, :page_opts, 1}) == []

      assert [%Issue{rule: "SL002", evidence: :possible_gradual, gate: false}] =
               issues(run, {Omission, :page_opts, 1})
    end
  end

  test "a baseline written without the flag does not acknowledge the newly gating finding",
       %{tmp_dir: tmp_dir} do
    ebin = Path.join(tmp_dir, "ebin")
    File.mkdir_p!(ebin)
    File.cp!(beam_path(Omission), Path.join(ebin, "#{Omission}.beam"))

    File.cp!(
      beam_path(SpecLint.OmissionFixtures.Page),
      Path.join(ebin, "#{SpecLint.OmissionFixtures.Page}.beam")
    )

    project = Project.from_ebins([{:fx, ebin}], tmp_dir)
    path = Path.join(tmp_dir, "baseline.json")
    off = %Config{baseline: "baseline.json"}

    {:ok, first} = Run.execute(project, off, ci: true)
    adapter = first.capabilities.adapter_id
    :ok = Baseline.write(path, Baseline.build(first.issues, first.inventory, adapter, nil))
    {:ok, acknowledged} = Run.execute(project, off, ci: true)
    assert acknowledged.exit_code == 0

    {:ok, run} = Run.execute(project, %{off | clause_local_qualification: true}, ci: true)
    assert [%Issue{gate: true, baseline: :new} = gating] = sl001(run, {Omission, :page_opts, 1})
    assert [%{"fingerprint" => fingerprint}] = run.baseline_decisions.gate_changed
    assert fingerprint == gating.fingerprint

    assert run.exit_code == 1
  end

  test "the flag changes prerequisites only, never evidence or the set of findings",
       %{off: off, on: on} do
    assert off.evidence == on.evidence
    key = &{&1.rule, &1.mfa, &1.slice, &1.clause, &1.evidence, &1.fingerprint}
    assert Enum.map(off.issues, key) == Enum.map(on.issues, key)

    result = Analysis.module(beam_path(ClauseLocal))
    assert Enum.all?(result.functions, &(&1.status == :compared))
  end
end
