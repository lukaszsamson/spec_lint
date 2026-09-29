defmodule SpecLint.ReportTest do
  use ExUnit.Case, async: true

  import SpecLint.TestHelpers

  alias SpecLint.ExperimentFixtures.Cases
  alias SpecLint.{Explain, Issue, Report, Run}
  alias SpecLint.Fixtures.Compare
  alias SpecLint.Report.{Console, Json}

  @moduletag :tmp_dir

  test "the JSON envelope is versioned and carries provenance" do
    run = run!([Compare], ci: true)
    envelope = Json.envelope(run)

    assert %{
             "schema" => "spec_lint/report",
             "schema_version" => 1,
             "tool" => %{"name" => "spec_lint", "version" => "0.1.0"},
             "adapter" => "1.21.0-dev+" <> _,
             "checker_version" => "elixir_checker_v10",
             "config" => %{"digest" => "sha256:" <> _, "profile" => "review", "ci" => true},
             "scope" => %{"partial" => true, "module_filters" => ["SpecLint.Fixtures.Compare"]},
             "capabilities" => %{"signatures" => true, "bodies" => false},
             "completion" => %{"status" => "partial", "exit_code" => 1},
             "baseline" => %{"applied" => false, "reason" => "missing"}
           } = envelope

    assert [%{"module" => "SpecLint.Fixtures.Compare", "md5" => md5, "path" => path}] =
             envelope["beams"]

    assert byte_size(md5) == 32
    # Relative to the project root when the build is inside it (the default
    # _build); a separate MIX_BUILD_PATH outside the root stays absolute.
    beam = Path.join(Mix.Project.compile_path(), "#{Compare}.beam")
    assert path == Path.relative_to(beam, File.cwd!())

    unless System.get_env("MIX_BUILD_PATH"),
      do: assert(path =~ ~r{^_build/test/lib/spec_lint/ebin/})

    assert %{"rule" => "SL001", "subject" => "SpecLint.Fixtures.Compare.disjoint/1"} =
             Enum.find(envelope["findings"], &(&1["rule"] == "SL001"))

    assert {:ok, decoded} = JSON.decode(IO.iodata_to_binary(Json.encode(envelope)))
    assert decoded["completion"]["blocking"] == Enum.count(run.issues, & &1.gate)
  end

  test "JSON output is byte identical across runs" do
    first = [Compare, Cases] |> run!(ci: true) |> Json.envelope() |> Json.encode()
    second = [Compare, Cases] |> run!(ci: true) |> Json.envelope() |> Json.encode()
    assert IO.iodata_to_binary(first) == IO.iodata_to_binary(second)
  end

  describe "rendering away from the run process" do
    test "Report.render/2 returns what the reporters render in the calling process" do
      run = run!([Compare, Cases], ci: true)
      assert run.issues != []

      assert Report.render(run, :json) ==
               run |> Json.envelope() |> Json.encode() |> IO.iodata_to_binary()

      assert Report.render(run, :console) == run |> Console.render() |> IO.iodata_to_binary()
    end

    test "the report view drops the analysis results and renders the same" do
      run = run!([Compare, Cases], ci: true)
      view = Report.view(run)

      assert run.modules != [] and run.evidence != %{} and run.inventory != []
      assert {view.modules, view.excluded, view.inventory} == {[], [], []}
      assert {view.evidence, view.reachability} == {%{}, %{}}
      assert %{view | issues: run.issues} == view
      assert Json.envelope(view) == Json.envelope(run)
      assert IO.iodata_to_binary(Console.render(view)) == IO.iodata_to_binary(Console.render(run))
    end

    # Printing a type loads struct modules, and a code load in the process
    # holding a large project's analysis took seconds (Milestone 1 review):
    # findings must be rendered in another process.
    test "the calling process renders no finding" do
      run = run!([Compare, Cases], ci: true)
      mfa = {Issue, :rendered_details, 1}
      test = self()
      tracer = spawn_link(fn -> forward_traces(test) end)
      :erlang.trace_pattern(mfa, true, [:global])
      :erlang.trace(self(), true, [:call, {:tracer, tracer}])

      try do
        # Control: rendering in this process is seen.
        _ = Json.envelope(run)
        sync_traces(tracer)
        assert_received {:trace, _, :call, {Issue, :rendered_details, [_]}}
        flush_traces()

        for format <- [:json, :console], do: Report.render(run, format)
        sync_traces(tracer)
        refute_received {:trace, _, :call, {Issue, :rendered_details, _}}
      after
        :erlang.trace(self(), false, [:call])
        :erlang.trace_pattern(mfa, false, [:global])
      end
    end
  end

  defp forward_traces(test) do
    receive do
      {:sync, ref} -> send(test, {:synced, ref})
      trace -> send(test, trace)
    end

    forward_traces(test)
  end

  defp flush_traces do
    receive do
      {:trace, _, _, _} -> flush_traces()
    after
      0 -> :ok
    end
  end

  # Every trace message of this process has reached the tracer and been
  # forwarded.
  defp sync_traces(tracer) do
    ref = :erlang.trace_delivered(self())
    assert_receive {:trace_delivered, _, ^ref}, 5_000
    send(tracer, {:sync, ref})
    assert_receive {:synced, ^ref}, 5_000
  end

  test "encode sorts keys and writes atomically", %{tmp_dir: tmp_dir} do
    assert IO.iodata_to_binary(Json.encode(%{b: [1, nil], a: %{}})) ==
             "{\n  \"a\": {},\n  \"b\": [1, null]\n}\n"

    path = Path.join([tmp_dir, "nested", "out.json"])
    assert :ok = Json.write_atomic(path, "x")
    assert File.read!(path) == "x"
    assert Path.wildcard(Path.join([tmp_dir, "nested", "*.tmp-*"])) == []
  end

  test "console output follows the documented message shape" do
    run = run!([Cases])
    text = run |> Console.render() |> IO.iodata_to_binary()

    assert text =~
             "test/support/experiment_fixtures.ex:30: SL002 possible_missing_return " <>
               "SpecLint.ExperimentFixtures.Cases.status/1 slice 0 [warning]\n" <>
               "  spec:            status(integer()) :: :ok | :error\n" <>
               "  inferred extra:  :timeout\n" <>
               "  slice:           (integer())\n" <>
               "  evidence:        structured_possible (signature backend, translation exact)\n" <>
               "  Review whether the spec should include this alternative.\n" <>
               "  policy:          reported, not gated: SL002 is informational"

    assert text =~ "Coverage:\n  modules: 1 discovered, 1 analysed"
    assert text =~ "  unknown obligations by reason: "
    assert text =~ "Result: partial, exit 0"
    assert text =~ "(new; fails with --ci)"
  end

  test "expand_opaque is labelled in the header, the findings, the ledger and the JSON" do
    alias SpecLint.Fixtures.Types
    config = %SpecLint.Config{baseline: "tmp/none.json", expand_opaque: true}
    run = run!([Types], [only: ["SL005"]], config)

    text = run |> Console.render() |> IO.iodata_to_binary()
    assert text =~ ", expand_opaque (opaque types expanded)"
    assert text =~ "translations with opaque or nominal types expanded (expand_opaque): 1"

    function = Enum.find(hd(run.modules).functions, &(&1.mfa == {Types, :opaque_remote, 1}))
    [slice] = function.slices
    assert SpecLint.Rule.translation_string(slice) =~ "(opaque expanded)"

    envelope = Json.envelope(run)
    assert envelope["config"]["expand_opaque"] == true
    assert envelope["ledger"]["slices"]["expanded"] == 1

    entry =
      Enum.find(
        envelope["ledger"]["entries"],
        &(&1["mfa"] == "SpecLint.Fixtures.Types.opaque_remote/1")
      )

    assert entry["notes"] == ["opaque_expanded"]

    plain = run!([Types], only: ["SL005"])
    refute plain |> Console.render() |> IO.iodata_to_binary() =~ "expand_opaque"
    assert Json.envelope(plain)["config"]["expand_opaque"] == false
  end

  test "--explain shows bounds, inferred clauses, containment and prerequisites" do
    mfa = {Cases, :lookup, 1}
    run = run!([Cases])
    assert {:ok, text} = Explain.render(run, mfa)
    text = IO.iodata_to_binary(text)

    assert text =~ "Spec clauses:\n  [0] lookup(:present | :missing) :: {:ok, integer()}"
    assert text =~ "argument 1 (exact):"
    assert text =~ "#1 (:missing) -> {:error, :missing}  [static return]"
    assert text =~ "applied clauses: #0, #1"
    assert text =~ "#1 contained, static return\n        class clause_conflict"
    assert text =~ "SL001 return_conflict slice 0 clause #1: clause_conflict"
    assert text =~ "clause_reachable unchecked"
    assert text =~ "policy: gates in the review profile"

    sign = run |> Explain.render({Cases, :sign, 1}) |> elem(1) |> IO.iodata_to_binary()
    assert sign =~ "loss integer_refinement_erased at argument 1\n"
    assert sign =~ "integers [{1, :infinity}]"
    assert sign =~ "SL002 is informational"

    assert {:error, message} = Explain.render(run, {Cases, :nope, 1})
    assert message =~ "has no spec"
    assert {:error, message} = Explain.render(run, {Run, :execute, 3})
    assert message =~ "was not analysed"
  end

  test "parse_mfa" do
    assert Explain.parse_mfa("MyApp.Store.lookup/1") == {:ok, {MyApp.Store, :lookup, 1}}
    assert Explain.parse_mfa("Kernel.+/2") == {:ok, {Kernel, :+, 2}}
    assert Explain.parse_mfa(":lists.map/2") == {:ok, {:lists, :map, 2}}
    assert {:error, _} = Explain.parse_mfa("lookup/1")
    assert {:error, _} = Explain.parse_mfa("Mod.fun/x")
  end
end
