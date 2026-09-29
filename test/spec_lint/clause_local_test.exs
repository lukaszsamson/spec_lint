defmodule SpecLint.ClauseLocalTest do
  @moduledoc """
  The clause-local qualification (`clause_local_qualification`, default
  `true` since the Close-phase decision, `SpecLint.Rules.ReturnConflict`,
  bench/corpus/clause_local_qualification.md), and the compiler check
  behind `clause_reachable` (`SpecLint.Reachability`).

  With the flag, an SL001 clause conflict needs its clause's whole domain
  contained in the spec's argument lower bounds instead of the slice-wide
  arrow prerequisites. The positive stand-ins are
  `SpecLint.OmissionFixtures.ClauseLocal` (Ash.Page.page_opts/1 and
  Oban.Registry.via/3, pinned in test/spec_lint/omissions_test.exs); the
  controls are `SpecLint.Fixtures.ClauseLocal` and the dead-clause probes
  below, which are compiled out of process because the compiler warns
  about them.
  """

  use ExUnit.Case, async: true

  import SpecLint.TestHelpers

  alias SpecLint.{
    Analysis,
    Baseline,
    CLI,
    Compare,
    Compiler,
    Config,
    Evidence,
    GuardFeasibility,
    Issue,
    Policy,
    Project,
    Reachability,
    Run
  }

  alias SpecLint.Fixtures.{ClauseLocal, Review}
  alias SpecLint.OmissionFixtures.ClauseLocal, as: Omission
  alias SpecLint.Report.Json
  alias SpecLint.Rules.ReturnConflict

  @moduletag :tmp_dir

  @off %Config{baseline: "tmp/none.json", clause_local_qualification: false}
  @on %Config{baseline: "tmp/none.json", clause_local_qualification: true}

  setup_all do
    %{
      off: run!([ClauseLocal, Omission, Review], [], @off),
      on: run!([ClauseLocal, Omission, Review], [], @on)
    }
  end

  defp sl001(run, mfa), do: run |> issues(mfa) |> Enum.filter(&(&1.rule == "SL001"))

  describe "configuration" do
    test "defaults to on, is validated, and is overridden by the command line" do
      assert %Config{}.clause_local_qualification

      assert {:ok, %Config{clause_local_qualification: true}} =
               Config.from_keyword(clause_local_qualification: true)

      assert {:error, message} = Config.from_keyword(clause_local_qualification: :yes)
      assert message =~ "invalid value for :clause_local_qualification"

      assert {:ok, cli} = CLI.parse(["--clause-local-qualification"])
      assert cli.clause_local_qualification
      assert {:ok, config} = Config.merge_cli(%Config{}, CLI.config_overrides(cli))
      assert config.clause_local_qualification

      assert {:ok, cli} = CLI.parse(["--no-clause-local-qualification"])
      refute cli.clause_local_qualification
      assert {:ok, config} = Config.merge_cli(%Config{}, CLI.config_overrides(cli))
      refute config.clause_local_qualification

      assert {:ok, cli} = CLI.parse([])
      assert {:ok, config} = Config.merge_cli(@off, CLI.config_overrides(cli))
      refute config.clause_local_qualification
      refute Config.digest(%Config{}) == Config.digest(%Config{clause_local_qualification: false})
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
    off = %Config{baseline: "baseline.json", clause_local_qualification: false}

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

  describe "clause_contained_in_lo is checked, not assumed" do
    test "an empty clause domain is contained in anything but never contained_lo?" do
      empty = Compiler.tuple([Compiler.none()])
      spec = Compiler.tuple([Compiler.atom([:a])])

      assert Compare.clause_containment(empty, spec, spec, false) == {:contained, false}
      assert Compare.clause_containment(empty, spec, spec, true) == {:contained, false}

      clause = Compiler.tuple([Compiler.atom([:a])])
      assert Compare.clause_containment(clause, spec, spec, true) == {:contained, true}

      # Inside D_hi only: containment unknown, not contained in D_lo.
      assert Compare.clause_containment(clause, spec, empty, true) ==
               {:containment_unknown, false}

      assert Compare.clause_containment(spec, clause, clause, false) == {:contained, true}
      other = Compiler.tuple([Compiler.atom([:b])])
      assert Compare.clause_containment(other, spec, spec, false) == {:domain_escape, false}
    end

    test "a clause conflict whose clause is not contained_lo? is blocked by it" do
      context = rule_context(Omission, :page_opts, 1, true, {:ok, []})
      assert [issue] = ReturnConflict.check_function(context)
      assert {:clause_contained_in_lo, :met} in issue.prerequisites
      assert Policy.gate?(issue, @on)

      [%{slice: slice} = slice_context] = context.slices
      contributing = Enum.map(slice.relations.contributing, &%{&1 | contained_lo?: false})
      slice = put_in(slice.relations.contributing, contributing)
      context = %{context | slices: [%{slice_context | slice: slice}]}

      assert [issue] = ReturnConflict.check_function(context)
      assert %Issue{evidence: :clause_conflict, clause: 0} = issue
      assert Issue.blocked(issue) == [:clause_contained_in_lo]
      refute Policy.gate?(issue, @on)
    end
  end

  describe "clause_reachable follows the compiler's own pattern and guard check" do
    @dead_source """
    defmodule SpecLint.ClauseLocalProbe.Dead do
      @moduledoc false
      # Clause :b can never match: its guard contradicts its pattern, and the
      # compiler warns "this guard will never succeed". The checker stores it
      # as (:b) -> {:error, :b}, and no earlier clause covers it.
      @spec g(:a | :b | (pos_integer() -> atom())) :: :ok | :fine
      def g(:a), do: :ok
      def g(:b = x) when is_integer(x), do: {:error, x}
      def g(x) when is_atom(x), do: :fine
      def g(f) when is_function(f, 1), do: :ok

      # The same without the arrow: it gated under the slice-wide
      # prerequisites before the compiler check existed.
      @spec h(:a | :b) :: :ok | :fine
      def h(:a), do: :ok
      def h(:b = x) when is_integer(x), do: {:error, x}
      def h(x) when is_atom(x), do: :fine
    end

    defmodule SpecLint.ClauseLocalProbe.Index do
      @moduledoc false
      # Source clause 0 always raises, so the checker drops it: source
      # clause 1 is stored, and reported, as stored clause 0.
      @spec idx(:a | :b | :c | (pos_integer() -> atom())) :: :ok
      def idx(:a), do: raise(ArgumentError, "no :a")
      def idx(:b), do: {:error, :b}
      def idx(:c), do: :ok
      def idx(f) when is_function(f, 1), do: :ok
    end
    """

    setup %{tmp_dir: tmp_dir} do
      ebin = elixirc!(tmp_dir, @dead_source)
      project = Project.from_ebins([{:probe, ebin}], tmp_dir)
      {:ok, off} = Run.execute(project, %{@off | baseline: "none.json"}, ci: true)
      {:ok, on} = Run.execute(project, %{@on | baseline: "none.json"}, ci: true)
      %{ebin: ebin, probe_off: off, probe_on: on}
    end

    test "a clause whose guard contradicts its pattern never gates", %{
      ebin: ebin,
      probe_off: off,
      probe_on: on
    } do
      dead = SpecLint.ClauseLocalProbe.Dead

      for run <- [off, on], name <- [:g, :h] do
        assert [issue] = sl001(run, {dead, name, 1})
        assert %Issue{evidence: :clause_conflict, clause: 1, gate: false} = issue
        assert Issue.blocked(issue) -- [:no_arrow_polarity_argument] == [:clause_reachable]
        assert [line] = issue.data.pattern_diagnostic_lines
        assert is_integer(line)
        assert {"compiler pattern diagnostics", "lines #{line}"} in issue.details
      end

      # Runtime: no input reaches the dead clause. :b falls through to the
      # is_atom/1 clause.
      {:module, ^dead} = :code.load_abs(String.to_charlist(Path.join(ebin, "#{dead}")))
      g = Function.capture(dead, :g, 1)
      h = Function.capture(dead, :h, 1)
      assert g.(:b) == :fine
      assert h.(:b) == :fine
      assert g.(:a) == :ok
    end

    test "the reported clause is the stored signature clause", %{ebin: ebin, probe_on: on} do
      index = SpecLint.ClauseLocalProbe.Index
      assert [issue] = sl001(on, {index, :idx, 1})
      assert %Issue{evidence: :clause_conflict, clause: 0, gate: true} = issue
      assert {"stored signature clause", "#0 (:b) -> {:error, :b}"} in issue.details
      refute Map.has_key?(issue.data, :pattern_diagnostic_lines)

      # A true positive: the in-spec :b returns {:error, :b}; control :c.
      {:module, ^index} = :code.load_abs(String.to_charlist(Path.join(ebin, "#{index}")))
      idx = Function.capture(index, :idx, 1)
      assert idx.(:b) == {:error, :b}
      assert idx.(:c) == :ok
    end

    test "only functions with a clause conflict are checked", %{probe_on: on} do
      assert on.reachability |> Map.keys() |> Enum.sort() == [
               {SpecLint.ClauseLocalProbe.Dead, :g, 1},
               {SpecLint.ClauseLocalProbe.Dead, :h, 1},
               {SpecLint.ClauseLocalProbe.Index, :idx, 1}
             ]

      assert on.reachability[{SpecLint.ClauseLocalProbe.Index, :idx, 1}] == {:ok, []}
      assert Reachability.check(on.modules, %{}) == %{}
    end

    test "the stand-ins have no pattern diagnostics", %{on: on} do
      assert on.reachability[{Omission, :page_opts, 1}] == {:ok, []}
      assert on.reachability[{Omission, :via, 3}] == {:ok, []}
    end

    test "a check that could not run blocks under either qualification" do
      reason = {:error, {:checker_failed, "boom"}}

      assert [issue] =
               ReturnConflict.check_function(rule_context(Omission, :via, 3, true, reason))

      assert Issue.blocked(issue) == [:clause_reachable]
      assert issue.data.reachability_check =~ "unavailable"

      assert [issue] =
               ReturnConflict.check_function(rule_context(Omission, :via, 3, false, reason))

      assert Issue.blocked(issue) == [:clause_reachable]
      assert {:clause_reachable, :blocked} in issue.prerequisites
    end
  end

  test "compound impossible guards cannot qualify clause conflicts", %{tmp_dir: tmp_dir} do
    source = """
    defmodule SpecLint.ClauseLocalProbe.Compound do
      @moduledoc false
      defguardp impossible(x) when is_integer(x) and is_atom(x)
      defguardp integer(x) when is_integer(x)

      @spec direct(:a | :b) :: :ok
      def direct(:b = x) when is_integer(x) and is_atom(x), do: {:error, :bad}
      def direct(x) when is_atom(x), do: :ok

      @spec macro_guard(:a | :b) :: :ok
      def macro_guard(:b = x) when impossible(x), do: {:error, :bad}
      def macro_guard(x) when is_atom(x), do: :ok

      @spec single(:a | :b) :: :ok
      def single(:b = x) when is_integer(x), do: {:error, :bad}
      def single(x) when is_atom(x), do: :ok

      @spec single_macro(:a | :b) :: :ok
      def single_macro(:b = x) when integer(x), do: {:error, :bad}
      def single_macro(x) when is_atom(x), do: :ok

      @spec feasible(:a | :b) :: :ok
      def feasible(:b = x) when is_atom(x), do: {:error, :bad}
      def feasible(x) when is_atom(x), do: :ok
    end
    """

    ebin = elixirc!(tmp_dir, source)
    project = Project.from_ebins([{:probe, ebin}], tmp_dir)

    for config <- [@off, @on] do
      {:ok, run} = Run.execute(project, %{config | baseline: "none.json"}, ci: true)
      module = SpecLint.ClauseLocalProbe.Compound

      for name <- [:direct, :macro_guard] do
        assert [issue] = sl001(run, {module, name, 1})
        refute issue.gate
        assert :clause_reachable in Issue.blocked(issue)
        assert issue.data.guard_feasibility == "unproven"
        assert run.reachability[{module, name, 1}] == {:ok, {:guard_unproven, []}}
      end

      for name <- [:single, :single_macro] do
        assert [issue] = sl001(run, {module, name, 1})
        refute issue.gate
        assert :clause_reachable in Issue.blocked(issue)
        assert {:ok, [_ | _]} = run.reachability[{module, name, 1}]
      end

      assert [issue] = sl001(run, {module, :feasible, 1})
      assert issue.gate
      assert run.reachability[{module, :feasible, 1}] == {:ok, []}
    end
  end

  test "guard witnesses satisfy repeated variables and exclude preceding clauses" do
    x = {:x, [version: 0], nil}
    is_atom = {{:., [], [:erlang, :is_atom]}, [], [x]}
    is_integer = {{:., [], [:erlang, :is_integer]}, [], [x]}
    repeated = {:{}, [], [x, x]}
    head = fn pattern, guards -> {[], [pattern], guards, nil} end
    definition = fn clauses -> {{:f, 1}, :def, [], clauses} end

    assert GuardFeasibility.proven?([definition.([head.(repeated, [is_atom])])])
    refute GuardFeasibility.proven?([definition.([head.({:=, [], [:b, x]}, [is_integer])])])

    # A witness for the later guarded head is intercepted by the first head,
    # even if that first clause always raises and is absent from ExCk.
    refute GuardFeasibility.proven?([
             definition.([{[], [:b], [], :raises}, head.({:=, [], [:b, x]}, [is_atom])])
           ])

    unknown = {{:., [], [:erlang, :unsupported_guard]}, [], [x]}
    partly_known = {{:., [], [:erlang, :orelse]}, [], [is_atom, unknown]}

    # Unknown evaluation of an earlier guard cannot establish exclusion.
    refute GuardFeasibility.proven?([
             definition.([head.(x, [partly_known]), head.(x, [is_integer])])
           ])

    refute GuardFeasibility.proven?([definition.([head.(x, [unknown])])])
  end

  test "numeric guard witnesses must satisfy all comparisons" do
    x = {:x, [version: 0], nil}
    greater = {{:., [], [:erlang, :>]}, [], [x, 5]}
    lesser = {{:., [], [:erlang, :<]}, [], [x, 3]}
    impossible = {{:., [], [:erlang, :andalso]}, [], [greater, lesser]}
    definition = fn guard -> {{:f, 1}, :def, [], [{[], [x], [guard], nil}]} end

    refute GuardFeasibility.proven?([definition.(impossible)])
    assert GuardFeasibility.proven?([definition.(lesser)])
  end

  test "multiple when guards are alternatives for the current and preceding clauses" do
    x = {:x, [version: 0], nil}
    is_atom = {{:., [], [:erlang, :is_atom]}, [], [x]}
    is_integer = {{:., [], [:erlang, :is_integer]}, [], [x]}
    equals_one = {{:., [], [:erlang, :"=:="]}, [], [x, 1]}
    head = fn pattern, guards -> {[], [pattern], guards, nil} end
    definition = fn clauses -> {{:f, 1}, :def, [], clauses} end

    assert GuardFeasibility.proven?([definition.([head.(x, [is_atom, is_integer])])])

    # The first guard accepts 2 although the second rejects it. A later
    # literal-2 clause has no reachable witness even if that first body raises.
    refute GuardFeasibility.proven?([
             definition.([
               {[], [x], [is_integer, equals_one], :raises},
               head.(2, [is_integer])
             ])
           ])
  end

  test "wide guard search is bounded and remains conservative" do
    variables = for i <- 0..7, do: {String.to_atom("x#{i}"), [version: i], nil}
    [first | _] = variables
    guard = {{:., [], [:erlang, :is_atom]}, [], [first]}
    definition = {{:f, 8}, :def, [], [{[], variables, [guard], nil}]}
    assert GuardFeasibility.proven?([definition])
  end

  test "dynamic struct witnesses bind the tag and satisfy nested fields" do
    module = {:module, [version: 0], nil}
    value = {:value, [version: 1], nil}
    struct = {:%, [], [module, {:%{}, [], []}]}
    alias_pattern = {:=, [], [struct, value]}
    is_foo = {{:., [], [:erlang, :"=:="]}, [], [module, :foo]}

    definition = fn patterns, guard ->
      {{:f, length(patterns)}, :def, [], [{[], patterns, [guard], nil}]}
    end

    assert GuardFeasibility.proven?([definition.([alias_pattern], is_foo)])
    assert GuardFeasibility.proven?([definition.([struct, module], is_foo)])

    wrong_tag = {:%, [], [module, {:%{}, [], [__struct__: :bar]}]}
    refute GuardFeasibility.proven?([definition.([wrong_tag], is_foo)])

    unsupported_field = {:%, [], [module, {:%{}, [], [field: {:<<>>, [], []}]}]}
    refute GuardFeasibility.proven?([definition.([unsupported_field], is_foo)])

    matcher = fn
      %tag{} = map -> {tag, map}
      _ -> :miss
    end

    assert matcher.(%{__struct__: :foo}) == {:foo, %{__struct__: :foo}}
    assert matcher.(%{__struct__: 1}) == :miss
  end

  test "an earlier dynamic struct clause intercepts later guarded witnesses" do
    module = {:module, [version: 0], nil}
    struct = {:%, [], [module, {:%{}, [], []}]}
    guard = {{:., [], [:erlang, :"=:="]}, [], [module, :foo]}
    is_map = {{:., [], [:erlang, :is_map]}, [], [{:value, [version: 1], nil}]}
    later = {:%{}, [], [__struct__: :foo]}

    refute GuardFeasibility.proven?([
             {{:f, 1}, :def, [], [{[], [struct], [guard], :raises}, {[], [later], [true], nil}]}
           ])

    # An unsupported nested field in a preceding clause blocks exclusion.
    unknown = {:%, [], [module, {:%{}, [], [field: {:<<>>, [], []}]}]}

    refute GuardFeasibility.proven?([
             {{:f, 1}, :def, [], [{[], [unknown], [is_map], nil}, {[], [later], [true], nil}]}
           ])
  end

  defp rule_context(module, name, arity, clause_local?, check) do
    result = Analysis.module(beam_path(module))
    function = Enum.find(result.functions, &(&1.mfa == {module, name, arity}))

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
      clause_local_qualification: clause_local?,
      pattern_diagnostics: check
    }
  end
end
