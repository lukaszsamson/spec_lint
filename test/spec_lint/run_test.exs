defmodule SpecLint.RunTest do
  use ExUnit.Case, async: true

  import SpecLint.TestHelpers

  alias SpecLint.{Config, Issue, Project, Run}
  alias SpecLint.ExperimentFixtures.Cases
  alias SpecLint.Fixtures.{Compare, Types}

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
