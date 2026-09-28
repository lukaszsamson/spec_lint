defmodule SpecLint.BaselineTest do
  use ExUnit.Case, async: true

  import SpecLint.TestHelpers

  alias SpecLint.{Baseline, Config, Issue, Project, Run}
  alias SpecLint.Fixtures.Compare

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
      do: map |> SpecLint.Report.Json.encode() |> IO.iodata_to_binary() |> Baseline.parse()

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

    assert Baseline.load("tmp/definitely/missing.json") == :missing
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
    assert length(third.baseline_decisions.stale_findings) == length(first.issues)

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
end
