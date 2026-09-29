defmodule SpecLint.CompilerGatingTest do
  use ExUnit.Case, async: true

  import SpecLint.TestHelpers

  alias SpecLint.{Baseline, Compiler, Config, Policy, Project, Run}
  alias SpecLint.OmissionFixtures.ClauseLocal, as: Omission

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    ebin = Path.join(dir, "ebin")
    File.mkdir_p!(ebin)
    File.cp!(beam_path(Omission), Path.join(ebin, "#{Omission}.beam"))
    {:ok, caps} = Compiler.preflight()

    # Exercise policy on real descriptor analysis without installing a bad
    # compiler. Real-build behavior is pinned by UpstreamQualificationTest.
    caps = %{caps | revision: "648b2a9"}
    %{project: Project.from_ebins([{:fixture, ebin}], dir), caps: caps, dir: dir}
  end

  test "diagnostic-only inference cannot certify CI or warnings-as-errors", context do
    for ci? <- [false, true], warnings? <- [false, true] do
      config = %Config{baseline: "missing.json", warnings_as_errors: warnings?}
      {:ok, run} = run(context, config, ci: ci?)

      assert run.completion == :incomplete
      assert run.exit_code == if(ci? or warnings?, do: 2, else: 0)
      assert run.issues != []
      assert Enum.all?(run.issues, &(not &1.gate))
      assert Enum.all?(run.issues, &(not Policy.gate?(&1, config)))
      assert Enum.all?(Policy.apply_gates(run.issues, config, MapSet.new()), &(not &1.gate))
      assert Enum.any?(run.completion_reasons, &(&1 =~ "diagnostic-only"))
      assert Policy.explain(hd(run.issues), config) =~ "diagnostic-only"
    end
  end

  test "baseline acknowledgement cannot hide the compiler restriction", context do
    config = %Config{baseline: "baseline.json"}
    {:ok, first} = run(context, config, ci: true)

    :ok =
      Baseline.write(
        Path.join(context.dir, config.baseline),
        Baseline.build(first.issues, first.inventory, first.capabilities.adapter_id, nil)
      )

    {:ok, second} = run(context, config, ci: true)
    assert second.completion == :incomplete
    assert second.exit_code == 2
    assert Enum.any?(second.completion_reasons, &(&1 =~ "diagnostic-only"))
  end

  test "rule selection cannot bypass compiler qualification", context do
    {:ok, result} = run(context, %Config{baseline: "none.json"}, ci: true, only: ["SL008"])
    assert result.exit_code == 2
    assert result.completion == :incomplete
  end

  test "both short and full known-bad revisions are diagnostic-only" do
    assert Compiler.Gating.reasons(%{revision: "648b2a9"}) != []
    assert Compiler.Gating.reasons(%{revision: "648b2a94934664cfd2c788348d02d799c68faa69"}) != []
    assert Compiler.Gating.reasons(%{revision: "c24c235"}) == []
    assert Compiler.Gating.reasons(%{revision: "759443e"}) == []
  end

  defp run(context, config, opts),
    do: Run.execute(context.project, config, Keyword.put(opts, :preflight, {:ok, context.caps}))
end
