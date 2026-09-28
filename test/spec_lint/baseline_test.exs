defmodule SpecLint.BaselineTest do
  use ExUnit.Case, async: true

  import SpecLint.TestHelpers

  alias SpecLint.{Baseline, Config, Issue, Project, Run}
  alias SpecLint.Fixtures.Compare
  alias SpecLint.Report.{Console, Json}

  @moduletag :tmp_dir

  @base """
  defmodule FpFixture do
    @spec conflict(atom()) :: integer()
    def conflict(a) when is_atom(a), do: a

    @spec two(atom()) :: integer()
    @spec two(integer()) :: integer()
    def two(x) when is_atom(x), do: x
    def two(x) when is_integer(x), do: x

    @spec other(integer()) :: integer()
    def other(x), do: x
  end
  """

  # Blank lines and a comment move every line.
  @line_change "# a comment\n\n\n" <> @base

  @reordered_functions """
  defmodule FpFixture do
    @spec other(integer()) :: integer()
    def other(x), do: x

    @spec two(atom()) :: integer()
    @spec two(integer()) :: integer()
    def two(x) when is_atom(x), do: x
    def two(x) when is_integer(x), do: x

    @spec conflict(atom()) :: integer()
    def conflict(a) when is_atom(a), do: a
  end
  """

  @reordered_spec String.replace(
                    @base,
                    "@spec two(atom()) :: integer()\n  @spec two(integer()) :: integer()",
                    "@spec two(integer()) :: integer()\n  @spec two(atom()) :: integer()"
                  )

  @changed_spec String.replace(
                  @base,
                  "@spec conflict(atom()) :: integer()",
                  "@spec conflict(atom()) :: binary()"
                )

  defp fingerprints(dir, source) do
    ebin = elixirc!(dir, source)
    {:ok, run} = Run.execute(Project.from_ebins([{:fx, ebin}], dir), %Config{baseline: "none"})
    Map.new(run.issues, &{{&1.rule, elem(&1.mfa, 1), &1.slice, &1.clause}, &1.fingerprint})
  end

  describe "fingerprint stability" do
    setup %{tmp_dir: tmp_dir} do
      base = fingerprints(Path.join(tmp_dir, "base"), @base)

      assert Map.keys(base) |> Enum.sort() == [
               {"SL001", :conflict, 0, nil},
               {"SL001", :two, 0, nil}
             ]

      %{base: base}
    end

    test "a line change keeps every fingerprint", %{tmp_dir: tmp_dir, base: base} do
      assert fingerprints(Path.join(tmp_dir, "lines"), @line_change) == base
    end

    test "reordering unrelated functions keeps every fingerprint", %{tmp_dir: t, base: base} do
      assert fingerprints(Path.join(t, "functions"), @reordered_functions) == base
    end

    test "reordering the spec's clauses changes the fingerprint", %{tmp_dir: t, base: base} do
      reordered = fingerprints(Path.join(t, "spec"), @reordered_spec)

      assert Map.keys(reordered) |> Enum.sort() == [
               {"SL001", :conflict, 0, nil},
               {"SL001", :two, 1, nil}
             ]

      assert reordered[{"SL001", :conflict, 0, nil}] == base[{"SL001", :conflict, 0, nil}]
      refute reordered[{"SL001", :two, 1, nil}] == base[{"SL001", :two, 0, nil}]
    end

    test "a changed spec changes the fingerprint", %{tmp_dir: tmp_dir, base: base} do
      changed = fingerprints(Path.join(tmp_dir, "changed"), @changed_spec)
      refute changed[{"SL001", :conflict, 0, nil}] == base[{"SL001", :conflict, 0, nil}]
      assert changed[{"SL001", :two, 0, nil}] == base[{"SL001", :two, 0, nil}]
    end

    test "an unchanged recompilation keeps every fingerprint", %{tmp_dir: t, base: base} do
      assert fingerprints(Path.join(t, "again"), @base) == base
    end

    test "a fresh VM computes the same fingerprints", %{tmp_dir: tmp_dir, base: base} do
      ebin = Path.join([tmp_dir, "base", "ebin"])

      script = """
      project = SpecLint.Project.from_ebins([{:fx, #{inspect(ebin)}}], #{inspect(tmp_dir)})
      {:ok, run} = SpecLint.Run.execute(project, %SpecLint.Config{baseline: "none"})
      for issue <- run.issues do
        IO.puts("\#{elem(issue.mfa, 1)} \#{issue.slice} \#{issue.fingerprint}")
      end
      """

      elixir = System.find_executable("elixir")
      {output, 0} = System.cmd(elixir, ["-pa", Mix.Project.compile_path(), "-e", script])

      fresh =
        for line <- String.split(output, "\n", trim: true), into: %{} do
          [name, slice, fingerprint] = String.split(line, " ")
          {{"SL001", String.to_atom(name), String.to_integer(slice), nil}, fingerprint}
        end

      assert fresh == base
    end
  end

  describe "fingerprint normalisation" do
    @spelled """
    defmodule FpSpelling do
      @type r :: :ok | pos_integer()
      @spec g(atom()) :: r()
      def g(a) when is_atom(a), do: {:error, a}

      @spec h(x) :: :none | :fine when x: atom()
      def h(a) when is_atom(a), do: {:error, a}
    end
    """

    # The same specs with the alias renamed, the unions reordered and the
    # type variable renamed.
    @respelled """
    defmodule FpSpelling do
      @type result :: pos_integer() | :ok
      @spec g(atom()) :: result()
      def g(a) when is_atom(a), do: {:error, a}

      @spec h(y) :: :fine | :none when y: atom()
      def h(a) when is_atom(a), do: {:error, a}
    end
    """

    test "renaming a type alias or variable and reordering a union keep fingerprints",
         %{tmp_dir: tmp_dir} do
      spelled = fingerprints(Path.join(tmp_dir, "spelled"), @spelled)

      assert Map.keys(spelled) |> Enum.sort() == [
               {"SL001", :g, 0, nil},
               {"SL001", :h, 0, nil}
             ]

      assert fingerprints(Path.join(tmp_dir, "respelled"), @respelled) == spelled

      # A spec whose meaning changes still changes the fingerprint.
      changed = String.replace(@spelled, ":none | :fine", ":none")
      refute fingerprints(Path.join(tmp_dir, "changed"), changed) == spelled
    end
  end

  test "strip_annotations removes lines and columns only" do
    ast = {:type, 12, :tuple, [{:atom, {3, 4}, :ok}, {:var, [line: 7], :x}]}
    assert Baseline.strip_annotations(ast) == {:type, 0, :tuple, [{:atom, 0, :ok}, {:var, 0, :x}]}
  end

  describe "decisions" do
    setup do
      run = run!([Compare])
      adapter = run.capabilities.adapter_id
      baseline = Baseline.build(run.issues, run.inventory, adapter, nil)
      %{run: run, adapter: adapter, baseline: baseline}
    end

    defp parsed(map),
      do: map |> Json.encode() |> IO.iodata_to_binary() |> Baseline.parse()

    test "a baseline acknowledges every finding it was built from", ctx do
      {:ok, baseline} = parsed(ctx.baseline)

      {issues, decisions} =
        Baseline.decide(ctx.run.issues, baseline, adapter: ctx.adapter, complete?: true)

      assert Enum.all?(issues, &(&1.baseline == :baselined))
      refute Enum.any?(issues, &Issue.blocking?/1)
      assert decisions.applied
      assert decisions.stale_findings == []
    end

    test "unmatched entries are stale only in complete runs", ctx do
      {:ok, baseline} = parsed(ctx.baseline)
      [dropped | kept] = ctx.run.issues

      {issues, decisions} = Baseline.decide(kept, baseline, adapter: ctx.adapter, complete?: true)
      assert Enum.all?(issues, &(&1.baseline == :baselined))
      assert [%{"fingerprint" => fingerprint}] = decisions.stale_findings
      assert fingerprint == dropped.fingerprint

      {_issues, partial} = Baseline.decide(kept, baseline, adapter: ctx.adapter, complete?: false)
      assert partial.stale_findings == []
    end

    test "expired entries count as new", ctx do
      expired =
        Map.update!(ctx.baseline, "findings", fn findings ->
          Enum.map(findings, &Map.put(&1, "expires", "2020-01-01"))
        end)

      {:ok, baseline} = parsed(expired)

      {issues, _} =
        Baseline.decide(ctx.run.issues, baseline, adapter: ctx.adapter, today: ~D[2026-09-28])

      assert Enum.all?(issues, &(&1.baseline == :expired))
      assert Enum.any?(issues, &Issue.blocking?/1)
    end

    test "stale entries only for the rules that ran and the slices compared", ctx do
      {:ok, baseline} = parsed(ctx.baseline)
      [dropped | kept] = ctx.run.issues
      opts = [adapter: ctx.adapter, complete?: true]

      # The rule of the dropped finding did not run: not stale.
      others = ctx.run.issues |> Enum.map(& &1.rule) |> Enum.uniq() |> List.delete(dropped.rule)
      {_, decisions} = Baseline.decide(kept, baseline, opts ++ [rules: others])
      assert decisions.stale_findings == []
      assert decisions.stale_inventory == []

      # Its slice is now unavailable: not stale.
      entry = %{
        module: "SpecLint.Fixtures.Compare",
        mfa: Issue.subject(dropped),
        slice: dropped.slice,
        status: "unavailable",
        reason: "no_signature"
      }

      {_, decisions} = Baseline.decide(kept, baseline, opts ++ [inventory: [entry]])
      assert decisions.stale_findings == []

      # Its whole module is unavailable: not stale.
      module = %{entry | mfa: nil, slice: nil, reason: "missing_metadata"}
      {_, decisions} = Baseline.decide(kept, baseline, opts ++ [inventory: [module]])
      assert decisions.stale_findings == []

      # A module whose name only prefixes the finding's does not hide it.
      other = %{module | module: "SpecLint.Fixtures"}
      {_, decisions} = Baseline.decide(kept, baseline, opts ++ [inventory: [other]])
      assert [%{"fingerprint" => fingerprint}] = decisions.stale_findings
      assert fingerprint == dropped.fingerprint
    end

    test "an SL008 for an unsupported checker chunk is never acknowledged", ctx do
      issue = %Issue{
        rule: "SL008",
        name: :analysis_unavailable,
        module: Compare,
        mfa: {Compare, :disjoint, 1},
        slice: 0,
        evidence: :unavailable,
        severity: :warning,
        message: "",
        gate: true,
        data: %{status: "unavailable", reason: "unsupported_chunk:elixir_checker_v9"}
      }

      ack = %{
        "mfa" => Issue.subject(issue),
        "slice" => 0,
        "status" => "unavailable",
        "acknowledged" => "x"
      }

      {:ok, baseline} = parsed(%{ctx.baseline | "inventory" => [ack]})
      {[decided], _} = Baseline.decide([issue], baseline, adapter: ctx.adapter)
      assert decided.baseline == :new

      ordinary = %{issue | data: %{status: "unavailable", reason: "no_signature"}}
      {[decided], _} = Baseline.decide([ordinary], baseline, adapter: ctx.adapter)
      assert decided.baseline == :baselined
    end

    test "regenerating keeps the entries of rules that did not run", ctx do
      {:ok, previous} = parsed(ctx.baseline)
      [first | _] = ctx.run.issues
      rules = ctx.run.issues |> Enum.map(& &1.rule) |> Enum.uniq() |> List.delete(first.rule)
      remaining = Enum.reject(ctx.run.issues, &(&1.rule == first.rule))

      rebuilt = Baseline.build(remaining, ctx.run.inventory, ctx.adapter, previous, rules: rules)
      assert Enum.any?(rebuilt["findings"], &(&1["fingerprint"] == first.fingerprint))
      assert length(rebuilt["findings"]) == length(ctx.baseline["findings"])

      dropped = Baseline.build(remaining, ctx.run.inventory, ctx.adapter, previous)
      refute Enum.any?(dropped["findings"], &(&1["fingerprint"] == first.fingerprint))
    end

    test "a disabled rule's entries from another adapter are pending, never baselined", ctx do
      # The review's repro: a baseline written by an older adapter
      # acknowledges an SL001 finding; SL001 is turned off and the baseline
      # regenerated under the running adapter; SL001 is turned back on.
      old_adapter = "1.21.0-dev+0ldc0de"

      old =
        ctx.baseline
        |> Map.put("adapter", old_adapter)
        |> Map.update!("findings", fn findings ->
          Enum.map(findings, &Map.put(&1, "adapter", old_adapter))
        end)

      {:ok, previous} = parsed(old)
      assert Enum.any?(ctx.run.issues, &(&1.rule == "SL001" and &1.gate))
      rules = ctx.run.issues |> Enum.map(& &1.rule) |> Enum.uniq() |> List.delete("SL001")
      remaining = Enum.reject(ctx.run.issues, &(&1.rule == "SL001"))

      rebuilt = Baseline.build(remaining, ctx.run.inventory, ctx.adapter, previous, rules: rules)
      assert rebuilt["adapter"] == ctx.adapter
      {kept, fresh} = Enum.split_with(rebuilt["findings"], &(&1["rule"] == "SL001"))
      assert kept != []

      # The SL001 entries keep their adapter and are pending; the others
      # were rechecked by the running adapter.
      assert Enum.all?(kept, &(&1["adapter"] == old_adapter and &1["pending_reconciliation"]))
      assert Enum.all?(fresh, &(&1["adapter"] == ctx.adapter))
      refute Enum.any?(fresh, &Map.has_key?(&1, "pending_reconciliation"))

      # SL001 re-enabled: its findings are new and gate; they are listed as
      # pending reconciliation and are not stale.
      {:ok, baseline} = parsed(rebuilt)

      {issues, decisions} =
        Baseline.decide(ctx.run.issues, baseline, adapter: ctx.adapter, complete?: true)

      {sl001, others} = Enum.split_with(issues, &(&1.rule == "SL001"))
      assert Enum.all?(sl001, &(&1.baseline == :new))
      assert Enum.any?(sl001, &Issue.blocking?/1)
      assert Enum.all?(others, &(&1.baseline == :baselined))
      assert Enum.sort(decisions.pending_reconciliation) == Enum.sort(kept)
      assert decisions.stale_findings == []

      # Regenerating with SL001 running reconciles: written afresh under the
      # running adapter, and every finding is acknowledged again.
      reconciled = Baseline.build(ctx.run.issues, ctx.run.inventory, ctx.adapter, baseline)
      assert Enum.all?(reconciled["findings"], &(&1["adapter"] == ctx.adapter))
      refute Enum.any?(reconciled["findings"], &Map.has_key?(&1, "pending_reconciliation"))
      {:ok, reconciled} = parsed(reconciled)
      {issues, decisions} = Baseline.decide(ctx.run.issues, reconciled, adapter: ctx.adapter)
      assert Enum.all?(issues, &(&1.baseline == :baselined))
      assert decisions.pending_reconciliation == []
    end

    test "an entry without its own adapter inherits the file's", ctx do
      findings = Enum.map(ctx.baseline["findings"], &Map.delete(&1, "adapter"))
      {:ok, baseline} = parsed(%{ctx.baseline | "findings" => findings})
      {issues, _} = Baseline.decide(ctx.run.issues, baseline, adapter: ctx.adapter)
      assert Enum.all?(issues, &(&1.baseline == :baselined))

      # A pending entry acknowledges nothing, even under the running adapter.
      pending = Enum.map(findings, &Map.put(&1, "pending_reconciliation", true))
      {:ok, baseline} = parsed(%{ctx.baseline | "findings" => pending})
      {issues, decisions} = Baseline.decide(ctx.run.issues, baseline, adapter: ctx.adapter)
      assert Enum.all?(issues, &(&1.baseline == :new))
      assert length(decisions.pending_reconciliation) == length(pending)
    end

    test "a pending entry regenerated under its own adapter acknowledges again", ctx do
      # The review's repro: an adapter-A entry of a rule that is off becomes
      # pending under B; the toolchain goes back to A and the baseline is
      # regenerated with the rule still off.
      [issue | _] = ctx.run.issues
      rules = ctx.run.issues |> Enum.map(& &1.rule) |> Enum.uniq() |> List.delete(issue.rule)
      remaining = Enum.reject(ctx.run.issues, &(&1.rule == issue.rule))

      {:ok, under_a} = parsed(ctx.baseline)
      under_b = Baseline.build(remaining, ctx.run.inventory, "other", under_a, rules: rules)
      {:ok, under_b} = parsed(under_b)
      assert Enum.any?(under_b.findings, &(&1["pending_reconciliation"] == true))

      back = Baseline.build(remaining, ctx.run.inventory, ctx.adapter, under_b, rules: rules)
      refute Enum.any?(back["findings"], &Map.has_key?(&1, "pending_reconciliation"))
      {:ok, back} = parsed(back)

      {issues, decisions} = Baseline.decide(ctx.run.issues, back, adapter: ctx.adapter)
      assert Enum.all?(issues, &(&1.baseline == :baselined))
      assert decisions.pending_reconciliation == []
    end

    test "an expires value that is not a date never suppresses a finding", ctx do
      for bad <- ["2020-13-45", "31/12/2020", "tomorrow", "2020-01-01T00:00:00Z", 20_200_101] do
        broken =
          Map.update!(ctx.baseline, "findings", fn [first | rest] ->
            [Map.put(first, "expires", bad) | rest]
          end)

        assert {:error, message} = parsed(broken)
        assert message =~ "expected null or an ISO 8601 date"
      end

      # A baseline built in memory with a bad date: the entry counts as new.
      {:ok, baseline} = parsed(ctx.baseline)
      findings = Enum.map(baseline.findings, &Map.put(&1, "expires", "2020-13-45"))

      {issues, _} =
        Baseline.decide(ctx.run.issues, %{baseline | findings: findings},
          adapter: ctx.adapter,
          today: ~D[2026-09-28]
        )

      assert Enum.all?(issues, &(&1.baseline == :expired))

      # A valid future date still acknowledges.
      future =
        Map.update!(ctx.baseline, "findings", fn findings ->
          Enum.map(findings, &Map.put(&1, "expires", "2027-01-01"))
        end)

      {:ok, baseline} = parsed(future)

      {issues, _} =
        Baseline.decide(ctx.run.issues, baseline, adapter: ctx.adapter, today: ~D[2026-09-28])

      assert Enum.all?(issues, &(&1.baseline == :baselined))
    end

    test "a baseline from another adapter is not applied", ctx do
      {:ok, baseline} = parsed(%{ctx.baseline | "adapter" => "other"})
      {issues, decisions} = Baseline.decide(ctx.run.issues, baseline, adapter: ctx.adapter)
      assert Enum.all?(issues, &(&1.baseline == :new))
      assert decisions.reason == :adapter_mismatch
    end

    test "regenerating keeps reason, owner and expires", ctx do
      {:ok, previous} =
        parsed(
          Map.update!(ctx.baseline, "findings", fn [first | rest] ->
            [Map.merge(first, %{"reason" => "known", "owner" => "team-x"}) | rest]
          end)
        )

      rebuilt = Baseline.build(ctx.run.issues, ctx.run.inventory, ctx.adapter, previous)
      assert [%{"reason" => "known", "owner" => "team-x"} | _] = rebuilt["findings"]
    end
  end

  test "parse rejects malformed baselines" do
    assert {:error, message} = Baseline.parse("{", "b.json")
    assert message =~ "invalid baseline JSON"
    assert {:error, message} = Baseline.parse(~s({"version": 9}), "b.json")
    assert message =~ "unsupported baseline version 9"

    assert {:error, _} =
             Baseline.parse(~s({"version": 1, "findings": [{"rule": "x"}], "inventory": []}))

    # A version 1 file with a malformed findings or inventory field is not
    # reported as an unsupported version.
    malformed = ~s({"version": 1, "findings": [{"fingerprint": "sha256:x"}], "inventory": "oops"})
    assert {:error, message} = Baseline.parse(malformed, "b.json")
    assert message =~ "invalid baseline b.json"
    assert message =~ ~s("findings" and "inventory" lists)
    refute message =~ "unsupported"

    assert Baseline.load("tmp/definitely/missing.json") == :missing
  end

  test "adapter change with a rule off, end to end: the rule's old entries gate again",
       %{tmp_dir: tmp_dir} do
    ebin = Path.join(tmp_dir, "ebin")
    File.mkdir_p!(ebin)
    File.cp!(beam_path(Compare), Path.join(ebin, "#{Compare}.beam"))
    project = Project.from_ebins([{:fx, ebin}], tmp_dir)
    path = Path.join(tmp_dir, "baseline.json")
    config = %Config{baseline: "baseline.json"}

    # A baseline acknowledging everything, as written by an older adapter.
    {:ok, first} = Run.execute(project, config, ci: true)
    assert first.exit_code == 1
    adapter = first.capabilities.adapter_id
    written = Baseline.build(first.issues, first.inventory, "1.21.0-dev+0ldc0de", nil)
    :ok = Baseline.write(path, written)

    {:ok, mismatch} = Run.execute(project, config, ci: true)
    assert mismatch.exit_code == 2

    # Regenerated under the running adapter with SL001 off (what
    # mix spec_lint.baseline does), then SL001 turned back on.
    off = %Config{config | rules: %{"SL001" => :off}}
    {:ok, previous} = Baseline.load(path)
    {:ok, without} = Run.execute(project, off, ci: true)
    ran = Enum.map(without.rules, fn {rule, _} -> rule.id() end)
    rebuilt = Baseline.build(without.issues, without.inventory, adapter, previous, rules: ran)
    :ok = Baseline.write(path, rebuilt)

    {:ok, again} = Run.execute(project, config, ci: true)
    assert again.baseline_decisions.applied
    assert [_ | _] = sl001 = Enum.filter(again.issues, &(&1.rule == "SL001"))
    assert Enum.all?(sl001, &(&1.baseline == :new))
    assert again.exit_code == 1
    assert again.baseline_decisions.pending_reconciliation != []

    json = again |> Json.envelope() |> Json.encode()
    pending = JSON.decode!(IO.iodata_to_binary(json))["baseline"]["pending_reconciliation"]
    assert [_ | _] = pending
    assert Enum.all?(pending, &(&1["rule"] == "SL001" and &1["pending_reconciliation"]))
  end

  test "baseline file end to end: acknowledge, go stale, acknowledge SL008", %{tmp_dir: tmp_dir} do
    ebin = Path.join(tmp_dir, "ebin")
    File.mkdir_p!(ebin)
    File.cp!(beam_path(Compare), Path.join(ebin, "#{Compare}.beam"))
    project = Project.from_ebins([{:fx, ebin}], tmp_dir)
    config = %Config{baseline: "baseline.json"}

    {:ok, first} = Run.execute(project, config, ci: true)
    assert first.exit_code == 1

    baseline = Baseline.build(first.issues, first.inventory, first.capabilities.adapter_id, nil)
    :ok = Baseline.write(Path.join(tmp_dir, "baseline.json"), baseline)
    {:ok, second} = Run.execute(project, config, ci: true)
    assert second.exit_code == 0
    assert Enum.all?(second.issues, &(&1.baseline == :baselined))

    # Stripping debug info makes the module unavailable: an SL008 that is a
    # coverage regression against the inventory, gated in CI.
    rebuild_beam(Compare, ebin, &List.keydelete(&1, ~c"Dbgi", 0))
    {:ok, third} = Run.execute(project, config, ci: true)
    assert [%{rule: "SL008", data: %{regression: true}} = sl008] = third.issues
    assert Issue.blocking?(sl008)
    assert third.exit_code == 1
    # The module was not analysed, so its acknowledged findings are not
    # stale: they come back when debug info does.
    assert third.baseline_decisions.stale_findings == []

    # With fail_on_regression: false a regression is reported, not gated.
    lenient = %Config{config | coverage: %{fail_on_regression: false, floor: 0}}
    {:ok, lenient_run} = Run.execute(project, lenient, ci: true)
    assert lenient_run.exit_code == 0

    # Acknowledging the unavailable module in the inventory accepts it.
    rebaseline = Baseline.build(third.issues, third.inventory, third.capabilities.adapter_id, nil)

    assert [%{"status" => "unavailable", "acknowledged" => "initial baseline"}] =
             rebaseline["inventory"]

    :ok = Baseline.write(Path.join(tmp_dir, "baseline.json"), rebaseline)
    {:ok, fourth} = Run.execute(project, config, ci: true)
    assert [%{rule: "SL008", baseline: :baselined}] = fourth.issues
    assert fourth.exit_code == 0
  end

  describe "gate state" do
    @overlapping """
    defmodule GateFx do
      @spec f(atom()) :: integer()
      @spec f(:a) :: atom()
      def f(x) when is_atom(x), do: x
    end
    """

    @alone """
    defmodule GateFx do
      @spec f(atom()) :: integer()
      def f(x) when is_atom(x), do: x
    end
    """

    test "a report-only finding in the baseline does not acknowledge it once it gates",
         %{tmp_dir: tmp_dir} do
      ebin = elixirc!(tmp_dir, @overlapping)
      project = Project.from_ebins([{:fx, ebin}], tmp_dir)
      config = %Config{baseline: "baseline.json"}
      path = Path.join(tmp_dir, "baseline.json")

      {:ok, first} = Run.execute(project, config, ci: true)
      assert [%Issue{rule: "SL001", slice: 0, gate: false} = blocked] = first.issues
      assert Issue.blocked(blocked) == [:no_overlap]
      assert first.exit_code == 0

      written = Baseline.build(first.issues, first.inventory, first.capabilities.adapter_id, nil)
      assert [%{"blocked" => ["no_overlap"]}] = written["findings"]
      # Without the removed overload's inventory entry, which would be a
      # coverage regression of its own (spec_clause_removed).
      written = Map.update!(written, "inventory", fn i -> Enum.reject(i, &(&1["slice"] == 1)) end)
      :ok = Baseline.write(path, written)

      # The overlapping overload goes: the same slice evidence, the same
      # fingerprint, but it gates now.
      File.rm_rf!(ebin)
      elixirc!(tmp_dir, @alone)
      {:ok, run} = Run.execute(project, config, ci: true)
      assert [%Issue{rule: "SL001", gate: true, baseline: :new} = gating] = run.issues
      assert Issue.blocking?(gating)
      assert gating.fingerprint == blocked.fingerprint
      assert [%{"fingerprint" => fingerprint}] = run.baseline_decisions.gate_changed
      assert fingerprint == blocked.fingerprint
      assert run.exit_code == 1

      json = run |> Json.envelope() |> Json.encode()
      assert [_] = JSON.decode!(IO.iodata_to_binary(json))["baseline"]["gate_changed"]
      assert Console.render(run) |> IO.iodata_to_binary() =~ "gate changed"

      # An entry written before the field existed acknowledges as before;
      # regenerating records the gating state and acknowledges it.
      legacy =
        Map.update!(written, "findings", fn f -> Enum.map(f, &Map.delete(&1, "blocked")) end)

      :ok = Baseline.write(path, legacy)
      {:ok, run} = Run.execute(project, config, ci: true)
      assert [%Issue{baseline: :baselined}] = run.issues
      assert run.exit_code == 0

      {:ok, previous} = Baseline.load(path)
      rebuilt = Baseline.build(run.issues, run.inventory, run.capabilities.adapter_id, previous)
      assert [%{"blocked" => []}] = rebuilt["findings"]
      :ok = Baseline.write(path, rebuilt)
      {:ok, run} = Run.execute(project, config, ci: true)
      assert [%Issue{baseline: :baselined}] = run.issues
      assert run.baseline_decisions.gate_changed == []
      assert run.exit_code == 0
    end
  end

  test "regenerating while a module is unavailable keeps its acknowledgements",
       %{tmp_dir: tmp_dir} do
    ebin = Path.join(tmp_dir, "ebin")
    File.mkdir_p!(ebin)
    File.cp!(beam_path(Compare), Path.join(ebin, "#{Compare}.beam"))
    project = Project.from_ebins([{:fx, ebin}], tmp_dir)
    config = %Config{baseline: "baseline.json"}
    path = Path.join(tmp_dir, "baseline.json")

    {:ok, first} = Run.execute(project, config, ci: true)
    adapter = first.capabilities.adapter_id
    :ok = Baseline.write(path, Baseline.build(first.issues, first.inventory, adapter, nil))
    {:ok, previous} = Baseline.load(path)
    compared = Enum.filter(previous.inventory, &(&1["status"] == "compared"))
    assert [_ | _] = previous.findings

    # Debug info off (a toolchain change): the module is unavailable, and
    # the baseline is regenerated from that complete run.
    rebuild_beam(Compare, ebin, &List.keydelete(&1, ~c"Dbgi", 0))
    {:ok, unavailable} = Run.execute(project, config, ci: true)
    assert [%{rule: "SL008", data: %{status: "unavailable"}}] = unavailable.issues
    rebuilt = Baseline.build(unavailable.issues, unavailable.inventory, adapter, previous)
    :ok = Baseline.write(path, rebuilt)

    # The findings and the compared slices are kept, next to the module's
    # acknowledged unavailable entry.
    assert Enum.sort_by(rebuilt["findings"], & &1["fingerprint"]) ==
             Enum.sort_by(previous.findings, & &1["fingerprint"])

    assert Enum.filter(rebuilt["inventory"], &(&1["status"] == "compared")) == compared
    assert [%{"status" => "unavailable"}] = Enum.reject(rebuilt["inventory"], & &1["mfa"])

    # Debug info back: every finding is acknowledged again, nothing is new.
    File.cp!(beam_path(Compare), Path.join(ebin, "#{Compare}.beam"))
    {:ok, restored} = Run.execute(project, config, ci: true)
    assert restored.exit_code == 0
    assert Enum.all?(restored.issues, &(&1.baseline == :baselined))
    assert [%{"status" => "unavailable"}] = restored.baseline_decisions.stale_inventory

    # A slice that is now unsupported keeps its finding the same way.
    [finding | _] = previous.findings
    entry = %{module: "SpecLint.Fixtures.Compare", mfa: finding["mfa"], slice: finding["slice"]}
    inventory = [Map.merge(entry, %{status: "unsupported", reason: "x", translation: nil})]
    rebuilt = Baseline.build([], inventory, adapter, previous)
    assert Enum.any?(rebuilt["findings"], &(&1["fingerprint"] == finding["fingerprint"]))
  end
end
