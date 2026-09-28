defmodule SpecLint.RunTest do
  use ExUnit.Case, async: true

  import SpecLint.TestHelpers

  alias SpecLint.{Baseline, Config, Issue, Project, Run}
  alias SpecLint.ExperimentFixtures.Cases
  alias SpecLint.Fixtures.{Compare, Review, Types}

  @moduletag :tmp_dir

  @config %Config{baseline: "tmp/none.json"}

  test "local runs report findings and exit 0; CI gates them with exit 1" do
    local = run!([Compare])
    assert Enum.any?(local.issues, &Issue.blocking?/1)
    assert local.exit_code == 0
    assert local.completion == :partial
    assert local.partial?

    ci = run!([Compare], ci: true)
    assert ci.exit_code == 1
  end

  test "a module with only report-only findings passes CI" do
    run = run!([Types], ci: true)
    refute Enum.any?(run.issues, &Issue.blocking?/1)
    assert run.exit_code == 0
  end

  test "--warnings-as-errors gates every reported finding, even locally" do
    config = %Config{@config | warnings_as_errors: true}
    run = run!([Cases], [], config)
    assert Enum.all?(run.issues, & &1.gate)
    assert run.exit_code == 1
  end

  test "filters: an unknown module or app is a configuration error" do
    assert {:error, message} = Run.execute(project(), @config, modules: [Nope.Missing])
    assert message =~ "Nope.Missing"
    assert {:error, message} = Run.execute(project(), @config, apps: [:other])
    assert message =~ "--app other"
  end

  test "an unsupported compiler exits 2 in CI and reports locally" do
    local = run!([Compare], preflight: {:error, :unqualified})
    assert local.completion == :incomplete
    assert local.exit_code == 0
    assert [reason] = local.completion_reasons
    assert reason =~ "unsupported compiler"

    ci = run!([Compare], preflight: {:error, :unqualified}, ci: true)
    assert ci.exit_code == 2
  end

  test "an internal failure analysing a module makes the run incomplete (exit 2)",
       %{tmp_dir: tmp_dir} do
    # Canary: a checker chunk whose clauses are not types crashes the
    # comparison. The run must not exit 0 after a worker failure.
    bad =
      :erlang.term_to_binary(
        {:elixir_erl.checker_version(),
         %{exports: [{{:disjoint, 1}, %{sig: {:infer, nil, [{[:bad], :bad}]}}}], mode: :elixir}}
      )

    ebin = Path.join(tmp_dir, "ebin")
    rebuild_beam(Compare, ebin, &List.keyreplace(&1, ~c"ExCk", 0, {~c"ExCk", bad}))
    project = Project.from_ebins([{:fx, ebin}], tmp_dir)

    for ci <- [false, true] do
      {:ok, run} = Run.execute(project, %Config{baseline: "none.json"}, ci: ci)
      assert run.completion == :incomplete
      assert run.exit_code == 2
      assert [reason] = run.completion_reasons
      assert reason =~ "internal failure analysing Elixir.SpecLint.Fixtures.Compare.beam"
    end
  end

  test "exclude globs move modules out of scope" do
    config = %Config{@config | exclude: ["test/support/**"]}
    run = run!([Compare], [], config)
    assert run.modules == []
    assert [%{module: Compare}] = run.excluded
    assert run.issues == []
    assert run.ledger["modules"]["out_of_scope"]["excluded"] == 1
  end

  test "coverage floor: fewer compared slices than the floor fails CI", %{tmp_dir: tmp_dir} do
    config = %Config{baseline: "none.json", coverage: %{fail_on_regression: true, floor: 1}}
    project = Project.from_ebins([{:empty, tmp_dir}], tmp_dir)
    {:ok, run} = Run.execute(project, config, ci: true)
    assert run.issues == []
    assert run.ledger["slices"]["found"] == 0
    assert [violation] = run.coverage_violations
    assert violation =~ "below the configured floor of 1"
    assert run.exit_code == 1

    {:ok, run} = Run.execute(project, %Config{baseline: "none.json"}, ci: true)
    assert run.exit_code == 0
  end

  test "coverage floor: a partial run does not check it", %{tmp_dir: tmp_dir} do
    ebin = Path.join(tmp_dir, "ebin")
    File.mkdir_p!(ebin)
    File.cp!(beam_path(Compare), Path.join(ebin, "#{Compare}.beam"))
    File.cp!(beam_path(Types), Path.join(ebin, "#{Types}.beam"))
    project = Project.from_ebins([{:fx, ebin}], tmp_dir)

    {:ok, full} = Run.execute(project, %Config{baseline: "none.json"}, only: ["SL002"])
    floor = full.ledger["slices"]["compared"]
    config = %Config{baseline: "none.json", coverage: %{fail_on_regression: true, floor: floor}}

    {:ok, full} = Run.execute(project, config, ci: true, only: ["SL002"])
    assert full.coverage_violations == []
    assert full.exit_code == 0

    {:ok, partial} = Run.execute(project, config, ci: true, only: ["SL002"], modules: [Compare])
    assert partial.ledger["slices"]["compared"] < floor
    assert partial.coverage_violations == []
    assert partial.completion == :partial
    assert partial.exit_code == 0

    assert Enum.any?(
             partial.completion_reasons,
             &(&1 =~ "coverage floor of #{floor} not checked")
           )
  end

  describe "coverage does not depend on rule selection" do
    setup %{tmp_dir: tmp_dir} do
      ebin = Path.join(tmp_dir, "ebin")
      File.mkdir_p!(ebin)
      File.cp!(beam_path(Compare), Path.join(ebin, "#{Compare}.beam"))
      project = Project.from_ebins([{:fx, ebin}], tmp_dir)
      config = %Config{baseline: "baseline.json"}

      {:ok, first} = Run.execute(project, config)
      baseline = Baseline.build(first.issues, first.inventory, first.capabilities.adapter_id, nil)
      :ok = Baseline.write(Path.join(tmp_dir, "baseline.json"), baseline)
      %{ebin: ebin, project: project, config: config, first: first}
    end

    test "entries of rules that did not run are not stale", ctx do
      for opts <- [[only: ["SL003"]], [except: ["SL001"]]] do
        {:ok, run} = Run.execute(ctx.project, ctx.config, [ci: true] ++ opts)
        assert run.completion == :complete
        assert run.baseline_decisions.stale_findings == []
        assert run.exit_code == 0
      end

      off = %Config{ctx.config | rules: %{"SL001" => :off}}
      {:ok, run} = Run.execute(ctx.project, off, ci: true)
      assert run.baseline_decisions.stale_findings == []
    end

    test "a module without debug info gates with SL008 left out", ctx do
      rebuild_beam(Compare, ctx.ebin, &List.keydelete(&1, ~c"Dbgi", 0))

      {:ok, run} = Run.execute(ctx.project, ctx.config, ci: true)
      assert [%{rule: "SL008", data: %{regression: true}}] = run.issues
      assert run.exit_code == 1

      off = %Config{ctx.config | rules: %{"SL008" => :off}}

      for {config, opts} <- [{ctx.config, [except: ["SL008"]]}, {off, []}] do
        {:ok, run} = Run.execute(ctx.project, config, [ci: true] ++ opts)
        assert run.issues == []
        assert [violation] = run.coverage_violations
        assert violation =~ "SpecLint.Fixtures.Compare is unavailable (missing_metadata)"
        assert violation =~ "a coverage regression"
        assert run.exit_code == 1

        # The module is unavailable, so none of its acknowledged findings
        # is stale, and its inventory entries are not acknowledgements.
        assert run.baseline_decisions.stale_findings == []
        assert run.baseline_decisions.stale_inventory == []
      end

      # --warnings-as-errors does not override the coverage policy: with
      # fail_on_regression: false the regression is reported, not gated.
      lenient = %Config{
        ctx.config
        | coverage: %{fail_on_regression: false, floor: 0},
          warnings_as_errors: true
      }

      {:ok, run} = Run.execute(ctx.project, lenient, ci: true)
      assert [%{rule: "SL008", gate: false} = issue] = run.issues
      assert SpecLint.Policy.explain(issue, lenient) =~ "fail_on_regression: false"
      assert run.exit_code == 0
    end
  end

  test "a checker chunk from another checker version fails preflight in CI",
       %{tmp_dir: tmp_dir} do
    fake = :erlang.term_to_binary({:elixir_checker_v1, %{exports: [], mode: :elixir}})
    ebin = Path.join(tmp_dir, "ebin")
    rebuild_beam(Compare, ebin, &List.keyreplace(&1, ~c"ExCk", 0, {~c"ExCk", fake}))
    project = Project.from_ebins([{:fx, ebin}], tmp_dir)

    {:ok, local} = Run.execute(project, %Config{baseline: "none.json"})
    assert local.completion == :incomplete
    assert local.exit_code == 0
    assert Enum.all?(local.issues, &(&1.data.reason == "unsupported_chunk:elixir_checker_v1"))

    {:ok, ci} = Run.execute(project, %Config{baseline: "none.json"}, ci: true)
    assert ci.completion == :incomplete
    assert ci.exit_code == 2
    assert [reason] = ci.completion_reasons
    assert reason =~ "version :elixir_checker_v1"
  end

  test "the ledger records why obligations are unknown" do
    run = run!([Review])
    ledger = run.ledger
    assert ledger["obligations_unknown_by_reason"] == %{"top_only" => 1}

    assert Enum.sum(Map.values(ledger["obligations_unknown_by_reason"])) ==
             Map.get(ledger["obligations"], "unknown", 0)

    stop = Enum.find(ledger["entries"], &(&1["mfa"] == "SpecLint.Fixtures.Review.stop/1"))
    assert %{"obligation" => "unknown", "unknown_reason" => "top_only", "notes" => []} = stop

    # SL006 reads top-only inference as unknown, not as a finding (DESIGN 4).
    assert issues(run, {Review, :stop, 1}) == []
  end

  test "the ledger counts with denominators" do
    run = run!([Compare])
    ledger = run.ledger
    slices = ledger["slices"]
    assert slices["found"] == slices["compared"]
    assert slices["unsupported"] == %{} and slices["unavailable"] == %{}
    assert slices["exact"] + slices["approximate"] == slices["compared"]
    assert ledger["functions"]["found"] >= ledger["functions"]["compared"]
    assert ledger["specs_out_of_scope"] == %{"macro" => 1, "not_exported" => 1}
    assert ledger["bodies"] == %{"requested" => false, "completed" => 0}
    assert Enum.sum(Map.values(ledger["obligations"])) == slices["compared"]
    assert length(ledger["entries"]) == slices["found"]
    assert %{"obligations" => %{"conflict" => 1, "rejected_domain" => 1}} = ledger
  end
end
