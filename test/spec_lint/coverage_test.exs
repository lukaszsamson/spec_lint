defmodule SpecLint.CoverageTest do
  use ExUnit.Case, async: true

  import SpecLint.TestHelpers

  alias SpecLint.{Baseline, Config, Coverage, Issue, Project, Run}
  alias SpecLint.Report.Console

  @moduletag :tmp_dir

  @v1 """
  defmodule LostFx do
    @spec kept(atom()) :: atom()
    def kept(a), do: privatised(a)

    @spec gone(atom()) :: atom()
    def gone(a), do: a

    @spec deleted(atom()) :: atom()
    def deleted(a), do: a

    @spec privatised(atom()) :: atom()
    def privatised(a), do: a
  end
  """

  # gone/1 loses its spec but stays exported; deleted/1 is deleted;
  # privatised/1 is no longer exported.
  @v2 """
  defmodule LostFx do
    @spec kept(atom()) :: atom()
    def kept(a), do: privatised(a)

    def gone(a), do: a

    defp privatised(a), do: a
  end
  """

  defp setup_project(tmp_dir) do
    ebin = elixirc!(tmp_dir, @v1)
    project = Project.from_ebins([{:fx, ebin}], tmp_dir)
    config = %Config{baseline: "baseline.json"}
    {:ok, first} = Run.execute(project, config, ci: true)
    assert first.exit_code == 0
    write_baseline(tmp_dir, first)
    {project, config}
  end

  defp write_baseline(tmp_dir, run) do
    baseline = Baseline.build(run.issues, run.inventory, run.capabilities.adapter_id, nil)
    :ok = Baseline.write(Path.join(tmp_dir, "baseline.json"), baseline)
    baseline
  end

  test "removing a @spec while keeping the function is a coverage regression",
       %{tmp_dir: tmp_dir} do
    {project, config} = setup_project(tmp_dir)
    elixirc!(tmp_dir, @v2)

    {:ok, run} = Run.execute(project, config, ci: true)
    assert run.exit_code == 1

    # Only the surviving function: a deleted or no longer exported function
    # is not a regression.
    assert [issue] = run.issues
    assert %Issue{rule: "SL008", mfa: {LostFx, :gone, 1}, slice: 0} = issue
    assert issue.data == %{status: "unanalysed", reason: "spec_removed", regression: true}
    assert Issue.blocking?(issue)
    assert Console.render(run) |> IO.iodata_to_binary() =~ "LostFx.gone/1 slice 0"

    assert [%{status: "unanalysed", mfa: "LostFx.gone/1", reason: "spec_removed"}] =
             Enum.filter(run.inventory, &(&1.status != "compared"))

    assert run.ledger["lost_analysis"] == %{"spec_removed" => 1}
    assert run.ledger["slices"]["found"] == 1

    # With SL008 not selected, it is a coverage violation naming the MFA.
    {:ok, except} = Run.execute(project, config, ci: true, except: ["SL008"])
    assert except.exit_code == 1
    assert [violation] = except.coverage_violations

    assert violation =~
             "LostFx.gone/1 slice 0 is unanalysed (spec_removed), a coverage regression"

    # fail_on_regression: false reports it without gating.
    lenient = %Config{config | coverage: %{fail_on_regression: false, floor: 0}}
    {:ok, lenient_run} = Run.execute(project, lenient, ci: true)
    assert [%{data: %{regression: true}, gate: false}] = lenient_run.issues
    assert lenient_run.exit_code == 0

    # Regenerating the baseline acknowledges the removal explicitly.
    rebuilt = write_baseline(tmp_dir, run)

    assert [
             %{
               "mfa" => "LostFx.gone/1",
               "status" => "unanalysed",
               "reason" => "spec_removed",
               "acknowledged" => "initial baseline"
             }
           ] = Enum.filter(rebuilt["inventory"], &(&1["status"] != "compared"))

    {:ok, acknowledged} = Run.execute(project, config, ci: true)
    assert [%{rule: "SL008", baseline: :baselined} = issue] = acknowledged.issues
    refute issue.data[:regression]
    assert acknowledged.exit_code == 0
    assert acknowledged.baseline_decisions.stale_inventory == []

    # The spec comes back: the acknowledgement is stale, nothing gates.
    elixirc!(tmp_dir, @v1)
    {:ok, restored} = Run.execute(project, config, ci: true)
    assert restored.issues == []
    assert restored.exit_code == 0
    assert [%{"mfa" => "LostFx.gone/1"}] = restored.baseline_decisions.stale_inventory
  end

  test "a spec that is now out of scope is lost analysis with its reason", %{tmp_dir: tmp_dir} do
    {project, _config} = setup_project(tmp_dir)
    {:ok, baseline} = Baseline.load(Path.join(tmp_dir, "baseline.json"))
    [module] = Run.execute(project, %Config{baseline: "none"}) |> elem(1) |> Map.fetch!(:modules)

    # gone/1's spec is listed out of scope (as a generated definition would be).
    gone = Enum.find(module.functions, &(&1.mfa == {LostFx, :gone, 1}))

    module = %{
      module
      | functions: List.delete(module.functions, gone),
        out_of_scope: [%{mfa: gone.mfa, reason: :generated}]
    }

    assert [%{mfa: "LostFx.gone/1", slice: 0, reason: "spec_out_of_scope:generated"}] =
             Coverage.lost_analysis([module], baseline)

    # Not analysed in this run (partial run, excluded, unavailable): nothing.
    assert Coverage.lost_analysis([], baseline) == []
    assert Coverage.lost_analysis([%{module | status: {:unavailable, :x}}], baseline) == []
    assert Coverage.lost_analysis([module], nil) == []
  end

  describe "build directories" do
    test "a missing ebin is an error, an empty one is zero specs", %{tmp_dir: tmp_dir} do
      missing = Path.join(tmp_dir, "_build/dev/lib/fx/ebin")
      project = Project.from_ebins([{:fx, missing}], tmp_dir)
      assert Project.check_build_paths(project) == {:error, :missing_build_path}
      assert [%{app: :fx}] = Project.missing_build_paths(project)

      assert {:error, message} = Run.execute(project, %Config{baseline: "none"}, ci: true)
      assert message =~ "missing build directory for fx (_build/dev/lib/fx/ebin)"

      File.mkdir_p!(missing)
      assert Project.check_build_paths(project) == :ok
      {:ok, run} = Run.execute(project, %Config{baseline: "none"}, ci: true)
      assert run.exit_code == 0
      assert run.completion == :complete
      assert run.ledger["functions"]["found"] == 0
      assert Console.render(run) |> IO.iodata_to_binary() =~ "0 specs checked"
    end

    test "only the selected applications are checked", %{tmp_dir: tmp_dir} do
      present = Path.join(tmp_dir, "a/ebin")
      File.mkdir_p!(present)
      project = Project.from_ebins([{:a, present}, {:b, Path.join(tmp_dir, "b/ebin")}], tmp_dir)
      assert {:error, message} = Run.execute(project, %Config{baseline: "none"})
      assert message =~ "missing build directory for b"

      assert {:ok, %Run{exit_code: 0}} =
               Run.execute(project, %Config{baseline: "none"}, apps: [:a])
    end
  end

  test "a module compiled from the test support keeps its exports" do
    result = SpecLint.Analysis.module(beam_path(SpecLint.Fixtures.Compare))
    assert {:disjoint, 1} in result.exports
  end
end
