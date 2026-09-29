defmodule SpecLint.CoverageTest do
  use ExUnit.Case, async: true

  import SpecLint.TestHelpers

  alias Mix.Compilers.Elixir, as: ElixirCompiler
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

  describe "overloads and injected defaults" do
    @overloads """
    defmodule OverFx do
      @spec pick(atom()) :: :a
      @spec pick(integer()) :: :b
      def pick(x) when is_atom(x), do: :a
      def pick(x) when is_integer(x), do: :b
    end
    """

    @one_overload """
    defmodule OverFx do
      @spec pick(integer()) :: :b
      def pick(x) when is_atom(x), do: :a
      def pick(x) when is_integer(x), do: :b
    end
    """

    @merged """
    defmodule OverFx do
      @spec pick(term()) :: term()
      def pick(x) when is_atom(x), do: :a
      def pick(x) when is_integer(x), do: :b
    end
    """

    defp baselined(tmp_dir, source) do
      ebin = elixirc!(tmp_dir, source)
      project = Project.from_ebins([{:fx, ebin}], tmp_dir)
      config = %Config{baseline: "baseline.json"}
      {:ok, first} = Run.execute(project, config, ci: true)
      assert first.exit_code == 0, inspect(first.issues)
      write_baseline(tmp_dir, first)
      {project, config}
    end

    test "removing one overload while another stays analysed is a regression",
         %{tmp_dir: tmp_dir} do
      {project, config} = baselined(tmp_dir, @overloads)

      for source <- [@one_overload, @merged] do
        File.rm_rf!(Path.join(tmp_dir, "ebin"))
        elixirc!(tmp_dir, source)
        {:ok, run} = Run.execute(project, config, ci: true)
        assert run.exit_code == 1

        # Slices are positional: the missing index is the last one.
        assert [%Issue{rule: "SL008", mfa: {OverFx, :pick, 1}, slice: 1} = issue] = run.issues

        assert issue.data == %{
                 status: "unanalysed",
                 reason: "spec_clause_removed",
                 regression: true
               }

        assert run.ledger["lost_analysis"] == %{"spec_clause_removed" => 1}
      end

      # Regenerating acknowledges it; restoring both overloads makes the
      # acknowledgement stale.
      {:ok, run} = Run.execute(project, config, ci: true)
      rebuilt = write_baseline(tmp_dir, run)

      assert [%{"slice" => 1, "status" => "unanalysed", "reason" => "spec_clause_removed"}] =
               Enum.filter(rebuilt["inventory"], &(&1["status"] != "compared"))

      {:ok, acknowledged} = Run.execute(project, config, ci: true)
      assert acknowledged.exit_code == 0
      assert [%{baseline: :baselined}] = acknowledged.issues

      File.rm_rf!(Path.join(tmp_dir, "ebin"))
      elixirc!(tmp_dir, @overloads)
      {:ok, restored} = Run.execute(project, config, ci: true)
      assert restored.issues == []

      assert [%{"mfa" => "OverFx.pick/1", "slice" => 1}] =
               restored.baseline_decisions.stale_inventory
    end

    @worker """
    defmodule WorkerFx do
      use GenServer

      @spec init(term()) :: {:ok, term()}
      def init(state), do: {:ok, state}

      @spec handle_info(term(), term()) :: {:noreply, term()}
      def handle_info(_msg, state), do: {:noreply, state}

      @spec child_spec(term()) :: map()
      def child_spec(arg), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}}
    end
    """

    # handle_info/2 and child_spec/1 deleted: the exports that remain are
    # GenServer's defoverridable defaults.
    @worker_defaults """
    defmodule WorkerFx do
      use GenServer

      @spec init(term()) :: {:ok, term()}
      def init(state), do: {:ok, state}
    end
    """

    # handle_info/2 keeps the user's definition but loses its spec.
    @worker_unspecced """
    defmodule WorkerFx do
      use GenServer

      @spec init(term()) :: {:ok, term()}
      def init(state), do: {:ok, state}

      def handle_info(_msg, state), do: {:noreply, state}
    end
    """

    test "deleting an override of a use-injected default is not a regression",
         %{tmp_dir: tmp_dir} do
      {project, config} = baselined(tmp_dir, @worker)

      File.rm_rf!(Path.join(tmp_dir, "ebin"))
      elixirc!(tmp_dir, @worker_defaults)
      {:ok, run} = Run.execute(project, config, ci: true)
      [module] = run.modules
      assert {:handle_info, 2} in module.exports
      assert {:handle_info, 2} in module.overridable_defaults
      assert {:child_spec, 1} in module.overridable_defaults
      refute {:init, 1} in module.overridable_defaults

      assert run.issues == []
      assert run.exit_code == 0

      # The baseline's compared entries of the deleted definitions are
      # stale, so the baseline is regenerated.
      assert ["WorkerFx.child_spec/1", "WorkerFx.handle_info/2"] =
               run.baseline_decisions.stale_inventory |> Enum.map(& &1["mfa"]) |> Enum.sort()

      # A user definition that only loses its spec is still spec_removed.
      File.rm_rf!(Path.join(tmp_dir, "ebin"))
      elixirc!(tmp_dir, @worker_unspecced)
      {:ok, run} = Run.execute(project, config, ci: true)

      assert [%Issue{mfa: {WorkerFx, :handle_info, 2}, data: %{reason: "spec_removed"}}] =
               run.issues

      assert run.exit_code == 1
    end
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

    test "an ebin missing BEAM files its .app lists is an error, not a smaller project",
         %{tmp_dir: tmp_dir} do
      {project, config} = setup_project(tmp_dir)
      ebin = Path.join(tmp_dir, "ebin")

      File.write!(
        Path.join(ebin, "fx.app"),
        ~s({application,fx,[{modules,['Elixir.LostFx']},{vsn,"0.1.0"}]}.\n)
      )

      assert Project.check_build_paths(project) == :ok
      File.rm!(Path.join(ebin, "Elixir.LostFx.beam"))
      assert Project.check_build_paths(project) == {:error, :missing_beams}
      assert [%{app: :fx, modules: [LostFx]}] = Project.missing_modules(project)

      assert {:error, message} = Run.execute(project, config, ci: true)
      assert message =~ "incomplete build"
      assert message =~ "fx (ebin): LostFx"

      # Without a module list (no .app file, no manifest) the run goes on,
      # and the baseline's compared entries of the vanished module are
      # reported as stale rather than silently dropped.
      File.rm!(Path.join(ebin, "fx.app"))
      {:ok, run} = Run.execute(project, config, ci: true)
      assert run.exit_code == 0
      assert run.ledger["functions"]["found"] == 0

      assert ["LostFx.deleted/1", "LostFx.gone/1", "LostFx.kept/1", "LostFx.privatised/1"] =
               run.baseline_decisions.stale_inventory |> Enum.map(& &1["mfa"]) |> Enum.sort()

      assert Console.render(run) |> IO.iodata_to_binary() =~
               "stale inventory entry: LostFx.gone/1 slice 0 (compared in the baseline"
    end

    test "an unreadable manifest falls back to the .app module list", %{tmp_dir: tmp_dir} do
      {project, config} = setup_project(tmp_dir)
      ebin = Path.join(tmp_dir, "ebin")
      manifest = Path.join(tmp_dir, "compile.elixir")

      File.write!(
        Path.join(ebin, "fx.app"),
        ~s({application,fx,[{modules,['Elixir.LostFx']},{vsn,"0.1.0"}]}.)
      )

      File.write!(manifest, "corrupt manifest")
      project = %{project | apps: [%{app: :fx, ebin: ebin, manifest: manifest}]}
      File.rm!(Path.join(ebin, "Elixir.LostFx.beam"))

      assert Project.check_build_paths(project) == {:error, :missing_beams}
      assert [%{modules: [LostFx]}] = Project.missing_modules(project)
      assert {:error, message} = Run.execute(project, config, ci: true)
      assert message =~ "incomplete build"
    end

    test "a readable empty manifest takes precedence over a stale .app module list",
         %{tmp_dir: tmp_dir} do
      ebin = Path.join(tmp_dir, "ebin")
      manifest = Path.join(tmp_dir, "compile.elixir")
      File.mkdir_p!(ebin)

      File.write!(
        Path.join(ebin, "fx.app"),
        ~s({application,fx,[{modules,['Elixir.LostFx']},{vsn,"0.1.0"}]}.\n)
      )

      # Preserve the compiler's actual manifest version and shape while
      # representing a successful compile with no remaining modules.
      source_manifest = Path.join(Mix.Project.manifest_path(), "compile.elixir")

      empty_manifest =
        source_manifest
        |> File.read!()
        |> :erlang.binary_to_term()
        |> put_elem(1, %{})
        |> put_elem(2, %{})

      File.write!(manifest, :erlang.term_to_binary(empty_manifest))
      assert ElixirCompiler.read_manifest(manifest) == {%{}, %{}}

      project = %{
        Project.from_ebins([{:fx, ebin}], tmp_dir)
        | apps: [
            %{app: :fx, ebin: ebin, manifest: manifest}
          ]
      }

      assert Project.check_build_paths(project) == :ok
      assert {:ok, run} = Run.execute(project, %Config{baseline: "none"}, ci: true)
      assert run.exit_code == 0
      assert run.ledger["functions"]["found"] == 0
    end

    test "a BEAM with an embedded module different from its filename is incomplete",
         %{tmp_dir: tmp_dir} do
      {project, config} = setup_project(tmp_dir)
      beam = Path.join(tmp_dir, "ebin/Elixir.LostFx.beam")
      [{OtherFx, binary}] = Code.compile_string("defmodule OtherFx do; def value, do: :ok; end")
      File.write!(beam, binary)

      assert Project.check_build_paths(project) == {:error, :module_mismatch}

      assert [%{app: :fx, path: ^beam, expected: "Elixir.LostFx", found: OtherFx}] =
               Project.mismatched_modules(project)

      assert {:error, message} = Run.execute(project, config, ci: true)
      assert message =~ "BEAM filename and embedded module disagree"
      assert message =~ "Elixir.LostFx.beam contains OtherFx"
    end

    test "a Mix app without a readable manifest or .app inventory is incomplete",
         %{tmp_dir: tmp_dir} do
      {project, config} = setup_project(tmp_dir)
      ebin = Path.join(tmp_dir, "ebin")
      manifest = Path.join(tmp_dir, "compile.elixir")
      File.write!(manifest, "corrupt manifest")
      owned = %{project | apps: [%{app: :fx, ebin: ebin, manifest: manifest}]}

      assert Project.check_build_paths(owned) == {:error, :missing_module_inventory}
      assert [%{app: :fx}] = Project.missing_module_inventories(owned)
      assert {:error, message} = Run.execute(owned, config, ci: true)
      assert message =~ "no readable module inventory for fx (ebin)"

      # A standalone ebin used by benchmark scripts has no Mix manifest and
      # may legitimately have no application resource file.
      assert Project.check_build_paths(project) == :ok
    end

    test "a corrupt BEAM is an incomplete build, not an acknowledgeable coverage gap",
         %{tmp_dir: tmp_dir} do
      {project, config} = setup_project(tmp_dir)
      beam = Path.join(tmp_dir, "ebin/Elixir.LostFx.beam")
      File.write!(beam, "not a BEAM")

      assert Project.check_build_paths(project) == {:error, :invalid_beam}
      assert [%{path: ^beam}] = Project.invalid_beams(project)
      assert {:error, message} = Run.execute(project, config, ci: true)
      assert message =~ "unreadable or invalid BEAM file"
      assert message =~ "ebin/Elixir.LostFx.beam"
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
