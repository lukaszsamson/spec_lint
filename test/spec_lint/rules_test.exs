defmodule SpecLint.RulesTest do
  use ExUnit.Case, async: true

  import SpecLint.TestHelpers

  alias SpecLint.{Config, Issue, Rules}
  alias SpecLint.ExperimentFixtures.Cases
  alias SpecLint.Fixtures.Compare

  @moduletag :tmp_dir

  defp all_rules, do: Enum.map(Rules.ids(), &String.downcase/1) -- ["sl007"]

  test "registry: IDs in order, lookup by ID or name" do
    assert Rules.ids() == ~w(SL001 SL002 SL003 SL004 SL005 SL006 SL007 SL008)
    assert Rules.find("sl002") == {:ok, Rules.PossibleMissingReturn}
    assert Rules.find(:possible_missing_return) == {:ok, Rules.PossibleMissingReturn}
    assert Rules.find(:SL008) == {:ok, Rules.AnalysisUnavailable}
    assert Rules.find("SL999") == :error

    for rule <- Rules.all() do
      assert rule.default_severity() in [:warning, :off]
      assert is_binary(rule.summary())
    end

    refute Rules.SpecDomainBodyWarning.available?()
  end

  test "SL001 slice level: applied return disjoint from the spec" do
    run = run!([Compare])
    assert [issue] = issues(run, {Compare, :disjoint, 1})
    assert %Issue{rule: "SL001", evidence: :conflict, slice: 0, clause: nil} = issue
    assert issue.message =~ "any normal return would be outside the spec"
    assert Issue.prerequisites_met?(issue)
    assert issue.gate
    assert String.starts_with?(issue.fingerprint, "sha256:")
    assert issue.file == "test/support/fixtures.ex"
    assert is_integer(issue.line)
  end

  test "SL001 clause level: a contained clause returns outside the spec" do
    run = run!([Cases])
    assert [issue] = issues(run, {Cases, :lookup, 1})
    assert %Issue{rule: "SL001", evidence: :clause_conflict, slice: 0, clause: 1} = issue
    assert {:clause_reachable, :unchecked} in issue.prerequisites
    assert issue.gate

    # The stale-spec shape (Join.escape/3): one issue per conflicting clause.
    assert [%{clause: 0}, %{clause: 1}] = issues(run, {Cases, :stale, 1})
  end

  test "SL001 clause level: a clause covered by earlier clauses is not gated" do
    # The compiler reports (:x) as redundant: no in-spec input reaches it.
    run = run!([Cases])
    assert [issue] = issues(run, {Cases, :shadowed, 1})
    assert %Issue{rule: "SL001", evidence: :clause_conflict, clause: 1} = issue
    assert {:clause_reachable, :blocked} in issue.prerequisites
    assert Issue.blocked(issue) == [:clause_reachable]
    refute issue.gate
    assert SpecLint.Policy.explain(issue, %Config{}) =~ "prerequisites blocked: clause_reachable"
  end

  test "SL001 with an inexact arrow argument is reported, never gated" do
    alias SpecLint.Fixtures.Review
    run = run!([Review], ci: true)
    assert [issue] = issues(run, {Review, :apply_it, 2})
    assert %Issue{rule: "SL001", evidence: :conflict} = issue
    assert {:no_arrow_polarity_argument, :blocked} in issue.prerequisites
    refute issue.gate

    assert [exact] = issues(run, {Review, :apply_exact, 2})
    assert {:no_arrow_polarity_argument, :met} in exact.prerequisites
    assert exact.gate
  end

  test "SL001 with an overlap tag is reported, never gated" do
    run = run!([Cases])
    assert [issue] = issues(run, {Cases, :pick, 1})
    assert issue.evidence == :clause_conflict
    assert Issue.blocked(issue) == [:no_overlap]
    refute issue.gate
  end

  test "SL001 with an unsupported sibling overload is gated only when shown disjoint" do
    alias SpecLint.{Evidence, Policy}
    alias SpecLint.Fixtures.Siblings
    alias SpecLint.Rules.ReturnConflict

    result = seeded_analysis(Siblings)

    sl001 = fn name ->
      function = Enum.find(result.functions, &(&1.mfa == {Siblings, name, 1}))

      slices =
        for slice <- function.slices do
          evidence = slice.relations && Evidence.classify(slice.relations)
          %{slice: slice, evidence: evidence}
        end

      context = %{
        module: result,
        function: function,
        file: nil,
        slices: slices,
        severity: :warning
      }

      Enum.map(ReturnConflict.check_function(context), &%{&1 | gate: Policy.gate?(&1, %Config{})})
    end

    # The sibling's argument cannot be translated: it may share inputs with
    # slice 0, so no_overlap blocks.
    assert [issue] = sl001.(:unsupported_sibling)
    assert %Issue{rule: "SL001", evidence: :conflict, slice: 0} = issue
    assert {:no_overlap, :blocked} in issue.prerequisites
    refute issue.gate

    # The sibling's argument translates and is disjoint: the conflict gates.
    assert [issue] = sl001.(:disjoint_sibling)
    assert %Issue{rule: "SL001", evidence: :conflict, slice: 0} = issue
    assert {:no_overlap, :met} in issue.prerequisites
    assert issue.gate
  end

  test "SL002 is reported for every possible class and never gated" do
    run = run!([Cases])
    status = issues(run, {Cases, :status, 1})
    assert [%Issue{rule: "SL002", evidence: :structured_possible} = issue] = status
    assert {"inferred extra", ":timeout"} in Issue.rendered_details(issue)
    refute issue.gate

    assert [%{evidence: :possible_domain_escape}] = issues(run, {Cases, :display, 1})
    assert [%{evidence: :possible_input_approximate}] = issues(run, {Cases, :sign, 1})
    assert issues(run, {Cases, :decode, 1}) == []
    assert issues(run, {Cases, :wide, 1}) == []
  end

  test "require_static_return turns gradual evidence into possible_gradual" do
    config = %Config{baseline: "tmp/none.json", require_static_return: true}
    run = run!([Cases], [], config)
    assert [%{rule: "SL002", evidence: :possible_gradual}] = issues(run, {Cases, :point, 1})
    assert [%{rule: "SL002", evidence: :possible_gradual}] = issues(run, {Cases, :stale, 1})
    assert [%{rule: "SL001"}] = issues(run, {Cases, :lookup, 1})
  end

  test "SL003: no inferred clause accepts the spec domain" do
    run = run!([Compare])
    assert [issue] = issues(run, {Compare, :rejected, 1})
    assert %Issue{rule: "SL003", evidence: :conflict} = issue
    assert {"disjoint positions", "argument 1"} in Issue.rendered_details(issue)
    assert issue.gate
  end

  test "SL006 gates in review, reports in soundness" do
    review = run!([Compare])
    assert [%{rule: "SL006", gate: true} = issue] = issues(review, {Compare, :halt, 1})
    assert issue.evidence == :unexpected_return

    soundness = run!([Compare], [], %Config{baseline: "tmp/none.json", profile: :soundness})
    assert [%{rule: "SL006", gate: false}] = issues(soundness, {Compare, :halt, 1})

    # A no_return() function that raises has no inferred return.
    assert issues(run!([Cases]), {Cases, :fail!, 1}) == []
  end

  test "SL004 and SL005 are off by default and hints when requested" do
    default = run!([Compare])
    refute Enum.any?(default.issues, &(&1.rule in ["SL004", "SL005"]))

    run = run!([Compare, Cases], only: ["SL004", "return_can_be_narrower"])
    assert Enum.all?(run.issues, &(&1.rule in ["SL004", "SL005"]))

    assert [%{rule: "SL004", evidence: :hint, severity: :hint, gate: false}] =
             issues(run, {Compare, :incomparable, 1})

    assert [%{rule: "SL005", evidence: :hint, gate: false} = narrower] =
             issues(run, {Cases, :wide, 1})

    assert {"never returned", _} =
             List.keyfind(Issue.rendered_details(narrower), "never returned", 0)
  end

  test "--except removes rules; SL007 cannot be requested" do
    run = run!([Cases], except: ["SL002"])
    refute Enum.any?(run.issues, &(&1.rule == "SL002"))

    config = %Config{baseline: "tmp/none.json"}
    assert {:error, message} = SpecLint.Run.execute(project(), config, only: ["SL007"])
    assert message =~ "body analysis backend"

    bodies = %Config{config | analysis: :bodies}
    assert {:error, message} = SpecLint.Run.execute(project(), bodies, [])
    assert message =~ "not available"
  end

  test "SL008: unavailable slices and unavailable modules", %{tmp_dir: tmp_dir} do
    fake = :erlang.term_to_binary({:elixir_checker_v1, %{exports: [], mode: :elixir}})
    ebin = Path.join(tmp_dir, "ebin")

    rebuild_beam(Compare, ebin, &List.keyreplace(&1, ~c"ExCk", 0, {~c"ExCk", fake}))
    rebuild_beam(Cases, ebin, &List.keydelete(&1, ~c"Dbgi", 0))

    project = SpecLint.Project.from_ebins([{:fx, ebin}], tmp_dir)
    config = %Config{baseline: "none.json"}
    {:ok, run} = SpecLint.Run.execute(project, config, only: all_rules())

    assert [module_issue] = Enum.filter(run.issues, &(&1.module == Cases))
    assert %Issue{rule: "SL008", mfa: nil, evidence: :unavailable} = module_issue
    assert module_issue.data.reason == "missing_metadata"
    assert module_issue.gate

    compare = Enum.filter(run.issues, &(&1.module == Compare))
    assert compare != []
    assert Enum.all?(compare, &(&1.rule == "SL008" and &1.evidence == :unavailable))
    # A checker chunk from another checker version is unsupported_chunk
    # (DESIGN.md 5.1), a preflight failure: the run is incomplete.
    assert Enum.all?(compare, &(&1.data.reason == "unsupported_chunk:elixir_checker_v1"))
    assert run.completion == :incomplete
    assert [reason] = run.completion_reasons
    assert reason =~ "unsupported checker chunk in SpecLint.Fixtures.Compare"
  end
end
