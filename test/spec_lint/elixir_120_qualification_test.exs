defmodule SpecLint.Elixir120QualificationTest do
  # Milestone 3: the fifteen-corpus replay under Elixir 1.20.4
  # (bench/corpus/reports/elixir-1.20.4/), compared with the same tool under
  # the fork revision c24c235. The recorded results are pinned here, so a
  # change in either replay or in its comparison turns the suite red. Pure
  # file checks: they run under every compiler.
  use ExUnit.Case, async: true

  @reports Path.expand("../../bench/corpus/reports", __DIR__)
  @oss ~w(jason decimal nimble_options mime plug ecto req broadway oban
          phoenix_live_view ash nx absinthe tesla)
  @corpora ["stdlib" | @oss]

  # Non-gating findings whose rendered slice lists union members in another
  # order (the compiler's printer), with everything else equal.
  @reordered ["Ash.load/3", "Ash.Test.refute_has_error/3", "Absinthe.Phase.Init.run/2"]

  test "every report is complete and names its adapter" do
    for corpus <- @corpora do
      new = report("elixir-1.20.4", corpus)
      base = report("elixir-1.20.4/c24c235", corpus)
      assert new["adapter"] == "1.20.4+759443e", corpus
      assert new["checker_version"] == "elixir_checker_v8", corpus
      assert base["adapter"] == "1.21.0-dev+c24c235", corpus
      assert new["completion"]["status"] == "complete", corpus
      assert base["completion"]["status"] == "complete", corpus
    end
  end

  test "the c24c235 replay with the Milestone 3 tool equals the Milestone 1 review replay" do
    # The adapter refactoring (Qualification, DescrWalk) changed nothing on
    # 1.21: only the fields added by the Milestone 2 review differ.
    for corpus <- @corpora do
      rerun = report("elixir-1.20.4/c24c235", corpus)
      m1 = report("m1_review", corpus)

      assert Map.drop(rerun, ["artifacts", "beams"]) == Map.drop(m1, ["artifacts", "beams"]),
             corpus

      assert Enum.map(rerun["beams"], &Map.take(&1, ["module", "md5", "path"])) ==
               Enum.map(m1["beams"], &Map.take(&1, ["module", "md5", "path"])),
             corpus
    end
  end

  test "the fourteen OSS corpora: the same ledger, findings, gates and exit codes" do
    for corpus <- @oss do
      new = report("elixir-1.20.4", corpus)
      base = report("elixir-1.20.4/c24c235", corpus)

      assert new["ledger"] == base["ledger"], corpus
      assert new["completion"]["exit_code"] == base["completion"]["exit_code"], corpus
      assert gates(new) == gates(base), corpus

      for {n, b} <- Enum.zip(new["findings"], base["findings"]) do
        assert Map.drop(n, ["fingerprint", "details"]) == Map.drop(b, ["fingerprint", "details"])

        if n["subject"] not in @reordered,
          do: assert(n["details"] == b["details"], "#{corpus}: #{n["subject"]}")
      end
    end
  end

  test "the gates, and the fingerprints the two lines share" do
    gates =
      for corpus <- @corpora, gate <- gates(report("elixir-1.20.4", corpus)), do: gate["subject"]

    assert Enum.frequencies(gates) == %{
             "Absinthe.Blueprint.Input.parse/1" => 7,
             "Ash.Page.page_opts/1" => 1,
             "Oban.Registry.via/3" => 1
           }

    shared =
      for corpus <- @corpora, reduce: 0 do
        acc ->
          base =
            MapSet.new(report("elixir-1.20.4/c24c235", corpus)["findings"], & &1["fingerprint"])

          acc +
            Enum.count(report("elixir-1.20.4", corpus)["findings"], &(&1["fingerprint"] in base))
      end

    assert shared == 28
  end

  test "the standard library: another library, no gate, three findings only 1.20.4 has" do
    new = report("elixir-1.20.4", "stdlib")
    base = report("elixir-1.20.4/c24c235", "stdlib")
    assert new["ledger"]["slices"]["compared"] == 1743
    assert base["ledger"]["slices"]["compared"] == 1777
    assert gates(new) == [] and gates(base) == []

    key = &{&1["subject"], &1["evidence"]}

    only_new =
      MapSet.difference(MapSet.new(new["findings"], key), MapSet.new(base["findings"], key))

    only_base =
      MapSet.difference(MapSet.new(base["findings"], key), MapSet.new(new["findings"], key))

    assert Enum.sort(only_new) == [
             {"DateTime.diff/3", "possible_domain_escape"},
             {"Float.round/2", "possible_domain_escape"},
             {"NaiveDateTime.diff/3", "possible_domain_escape"}
           ]

    assert Enum.sort(only_base) == [{"Float.round/2", "possible_input_approximate"}]
  end

  test "the fixture corpus: the same classes and accuracy on both lines" do
    new = experiment("elixir-1.20.4")
    base = experiment("elixir-1.20.4/c24c235")
    assert new["adapter"] == "1.20.4+759443e"
    assert new["totals"] == base["totals"]
    assert new["fixtures"] == base["fixtures"]

    classes = &Map.new(&1["functions"], fn f -> {f["mfa"], {f["class"], f["class_static"]}} end)
    assert classes.(new) == classes.(base)
  end

  test "baselines are per adapter" do
    for {adapter, corpus} <- baselines() do
      baseline = [@reports, "elixir-1.20.4/baselines", adapter, corpus <> ".json"]
      baseline = baseline |> Path.join() |> File.read!() |> JSON.decode!()
      dir = if adapter == "1.20.4+759443e", do: "elixir-1.20.4", else: "elixir-1.20.4/c24c235"
      findings = report(dir, corpus)["findings"]

      assert baseline["adapter"] == adapter
      assert Enum.all?(baseline["findings"], &(&1["adapter"] == adapter))

      assert Enum.sort(Enum.map(baseline["findings"], & &1["fingerprint"])) ==
               Enum.sort(Enum.map(findings, & &1["fingerprint"])),
             "#{adapter} #{corpus}"
    end
  end

  defp baselines do
    for adapter <- ["1.20.4+759443e", "1.21.0-dev+c24c235"],
        corpus <- ~w(ash oban absinthe),
        do: {adapter, corpus}
  end

  defp gates(report),
    do: for(f <- report["findings"], f["gate"], do: Map.take(f, ~w(subject rule slice clause)))

  defp experiment(dir),
    do: [@reports, dir, "fixtures.json"] |> Path.join() |> File.read!() |> JSON.decode!()

  defp report(dir, corpus),
    do:
      [@reports, dir, corpus <> ".spec_lint.json"]
      |> Path.join()
      |> File.read!()
      |> JSON.decode!()
end
