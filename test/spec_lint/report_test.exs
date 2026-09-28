defmodule SpecLint.ReportTest do
  use ExUnit.Case, async: true

  import SpecLint.TestHelpers

  alias SpecLint.{Explain, Run}
  alias SpecLint.ExperimentFixtures.Cases
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
    assert path =~ ~r{^_build/test/lib/spec_lint/ebin/}

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
               "  Review whether the spec should include this alternative.\n"

    assert text =~ "Coverage:\n  modules: 1 discovered, 1 analysed"
    assert text =~ "Result: partial, exit 0"
    assert text =~ "(new; fails with --ci)"
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
