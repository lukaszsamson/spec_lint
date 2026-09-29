defmodule SpecLint.ReachabilityFailureTest do
  use ExUnit.Case, async: false

  import SpecLint.TestHelpers

  alias SpecLint.{Baseline, Config, Issue, Project, Run}
  alias SpecLint.Fixtures.ClauseLocal
  alias SpecLint.OmissionFixtures.ClauseLocal, as: Omission

  @moduletag :tmp_dir

  # Fault injection at the real adapter boundary: all type and comparison
  # operations still use the running compiler's qualified adapter.
  defmodule FailedCheckAdapter do
    @behaviour SpecLint.Compiler

    for {name, arity} <- SpecLint.Compiler.behaviour_info(:callbacks),
        name != :pattern_diagnostics do
      args = Macro.generate_arguments(arity, __MODULE__)

      @impl true
      def unquote(name)(unquote_splicing(args)),
        do: apply(SpecLint.Compiler.running_adapter(), unquote(name), [unquote_splicing(args)])
    end

    @impl true
    def pattern_diagnostics(_module, _file, _attributes, _definitions),
      do: {:error, {:checker_failed, "injected review failure"}}
  end

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:spec_lint, :compiler_adapter)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:spec_lint, :compiler_adapter, previous),
        else: Application.delete_env(:spec_lint, :compiler_adapter)
    end)

    ebin = Path.join(dir, "ebin")
    File.mkdir_p!(ebin)
    File.cp!(beam_path(Omission), Path.join(ebin, "#{Omission}.beam"))
    %{project: Project.from_ebins([{:fx, ebin}], dir), dir: dir}
  end

  test "a required failed check is incomplete under both qualification settings and profiles",
       %{project: project} do
    for clause_local? <- [false, true], profile <- [:soundness, :review] do
      config = %Config{
        baseline: "missing.json",
        clause_local_qualification: clause_local?,
        profile: profile
      }

      with_failed_check(fn ->
        assert {:ok, run} = Run.execute(project, config, ci: true)
        assert run.completion == :incomplete
        assert run.exit_code == 2
        assert Enum.any?(run.completion_reasons, &(&1 =~ "required reachability check failed"))
        assert Enum.any?(run.completion_reasons, &(&1 =~ "injected review failure"))

        assert [%Issue{gate: false} = issue] = issues(run, {Omission, :via, 3}, "SL001")
        assert Issue.blocked(issue) == [:clause_reachable]
        assert issue.data.reachability_check =~ "unavailable"
        assert issue.data.reachability_check_required
      end)
    end
  end

  test "a baseline acknowledgment cannot turn a required check failure into a clean run",
       %{project: project, dir: dir} do
    baseline_path = Path.join(dir, "baseline.json")

    for clause_local? <- [false, true] do
      config = %Config{baseline: "baseline.json", clause_local_qualification: clause_local?}
      assert {:ok, first} = Run.execute(project, config, ci: true)

      :ok =
        Baseline.write(
          baseline_path,
          Baseline.build(first.issues, first.inventory, first.capabilities.adapter_id, nil)
        )

      with_failed_check(fn ->
        assert {:ok, run} = Run.execute(project, config, ci: true)
        assert run.completion == :incomplete
        assert run.exit_code == 2
        assert [_ | _] = run.completion_reasons

        assert [%Issue{baseline: :baselined, gate: false}] =
                 issues(run, {Omission, :via, 3}, "SL001")
      end)
    end
  end

  test "SL001 disabled does not invoke or require the failed check", %{project: project} do
    config = %Config{baseline: "missing.json"}

    with_failed_check(fn ->
      for opts <- [[only: ["SL003"]], [except: ["SL001"]]] do
        assert {:ok, run} = Run.execute(project, config, [ci: true] ++ opts)
        assert run.reachability == %{}
        assert run.completion != :incomplete
        refute Enum.any?(run.completion_reasons, &(&1 =~ "reachability"))
      end
    end)
  end

  test "a failed check with another blocked prerequisite is not required", %{
    project: project,
    dir: dir
  } do
    config = %Config{baseline: "missing.json", clause_local_qualification: false}

    # page_opts/1 has an arrow-polarity argument, so the slice-wide policy
    # cannot gate it even if reachability succeeds. via/3 is an eligible
    # check in the same module; inspect the page_opts/1 finding directly.
    with_failed_check(fn ->
      assert {:ok, run} = Run.execute(project, config, ci: true)
      assert [%Issue{gate: false} = issue] = issues(run, {Omission, :page_opts, 1}, "SL001")
      assert :no_arrow_polarity_argument in Issue.blocked(issue)
      refute issue.data[:reachability_check] == nil
      refute Enum.any?(run.completion_reasons, &(&1 =~ "page_opts/1"))
    end)

    # This project has clause conflicts, but each has another blocked
    # prerequisite under the slice-wide policy. Their failed checks are
    # observable on the findings without making the run incomplete.
    ebin = Path.join(dir, "blocked_ebin")
    File.mkdir_p!(ebin)
    File.cp!(beam_path(ClauseLocal), Path.join(ebin, "#{ClauseLocal}.beam"))
    blocked_project = Project.from_ebins([{:fx, ebin}], dir)

    with_failed_check(fn ->
      assert {:ok, run} = Run.execute(blocked_project, config, ci: true)
      assert run.completion == :complete
      assert run.exit_code == 0
      refute Enum.any?(run.completion_reasons, &(&1 =~ "reachability"))
      assert Enum.any?(run.issues, &(&1.rule == "SL001" and &1.data[:reachability_check]))
    end)
  end

  defp with_failed_check(fun) do
    Application.put_env(:spec_lint, :compiler_adapter, FailedCheckAdapter)

    try do
      fun.()
    after
      Application.delete_env(:spec_lint, :compiler_adapter)
    end
  end

  defp issues(run, mfa, rule), do: Enum.filter(run.issues, &(&1.mfa == mfa and &1.rule == rule))
end
