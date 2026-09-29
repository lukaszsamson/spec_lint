defmodule SpecLint.CorpusReportTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir
  @script Path.expand("../../bench/corpus/normalise_report.sh", __DIR__)
  @runner Path.expand("../../bench/corpus/run.sh", __DIR__)
  @compare Path.expand("../../bench/corpus/compare_replay.sh", __DIR__)
  @gate_diff Path.expand("../../bench/corpus/gate_diff.sh", __DIR__)
  @lines Path.expand("../../bench/corpus/toolchain/compare_lines.sh", __DIR__)

  test "large product reports retain the real ledger and completion plus full compressed JSON", %{
    tmp_dir: dir
  } do
    input = Path.join(dir, "input.json")
    output = Path.join(dir, "output.json")

    report = %{
      "adapter" => "adapter",
      "checker_version" => "checker",
      "completion" => %{"status" => "complete", "exit_code" => 1},
      "ledger" => %{"slices" => %{"compared" => 17}},
      "findings" => [%{"rule" => "SL001"}],
      "beams" => [%{"path" => String.duplicate("beam", 100)}]
    }

    File.write!(input, JSON.encode!(report))

    assert {"", 0} =
             System.cmd("bash", [@script, input, output],
               env: [{"SPEC_LINT_REPORT_LIMIT", "100"}]
             )

    summary = output |> File.read!() |> JSON.decode!()
    assert summary["completion"] == report["completion"]
    assert summary["ledger"] == report["ledger"]
    assert summary["finding_count"] == 1
    assert summary["findings"] == report["findings"]

    assert {full, 0} = System.cmd("gzip", ["-dc", output <> ".gz"])
    assert JSON.decode!(full)["beams"] == report["beams"]
  end

  test "large experiment reports retain class counts and candidates", %{tmp_dir: dir} do
    input = Path.join(dir, "experiment.json")
    output = Path.join(dir, "summary.json")

    report = %{
      "label" => "example",
      "adapter" => "adapter",
      "totals" => %{"functions" => 2, "runtime_ms" => 999},
      "functions" => [
        %{"class" => "unknown", "mfa" => String.duplicate("A", 100)},
        %{"class" => "structured_possible", "mfa" => "B.f/0"}
      ]
    }

    File.write!(input, JSON.encode!(report))

    assert {"", 0} =
             System.cmd("bash", [@script, input, output],
               env: [{"SPEC_LINT_REPORT_LIMIT", "100"}]
             )

    summary = output |> File.read!() |> JSON.decode!()
    assert summary["totals"] == %{"functions" => 2}
    assert summary["functions"] == [%{"class" => "structured_possible", "mfa" => "B.f/0"}]
    assert File.exists?(output <> ".gz")
  end

  test "normalizes both logical and canonical checkout paths", %{tmp_dir: dir} do
    checkout = Path.join(dir, "checkout")
    alias_path = Path.join(dir, "alias")
    File.mkdir_p!(checkout)
    File.ln_s!(checkout, alias_path)
    {canonical, 0} = System.cmd("pwd", ["-P"], cd: checkout)
    canonical = String.trim(canonical)
    input = Path.join(dir, "paths.json")
    output = Path.join(dir, "paths.normalized.json")

    File.write!(
      input,
      JSON.encode!(%{
        "adapter" => "adapter",
        "totals" => %{},
        "functions" => [],
        "paths" => [alias_path <> "/file.ex", canonical <> "/file.ex"]
      })
    )

    assert {"", 0} =
             System.cmd("bash", [@script, input, output], env: [{"SPEC_LINT_OSS", alias_path}])

    assert JSON.decode!(File.read!(output))["paths"] == ["$OSS/file.ex", "$OSS/file.ex"]
  end

  test "rejects unknown report schemas", %{tmp_dir: dir} do
    input = Path.join(dir, "invalid.json")
    output = Path.join(dir, "out.json")
    File.write!(input, ~s({"summary":{},"coverage":{},"exit_status":0}))

    assert {_message, 2} =
             System.cmd("bash", [@script, input, output], stderr_to_stdout: true)

    refute File.exists?(output)
  end

  test "corpus runner fails closed on an incomplete run while retaining its report", %{
    tmp_dir: dir
  } do
    {checkout, revision, bin} = setup_mock_corpus(dir)
    manifest = Path.join(dir, "manifest.json")
    out = Path.join(dir, "reports")
    File.write!(manifest, JSON.encode!(%{"fake" => %{"revision" => revision}}))

    {message, 2} =
      System.cmd("bash", [@runner, "fake"],
        env: corpus_env(dir, manifest, out, bin),
        stderr_to_stdout: true
      )

    assert message =~ "incomplete product run for fake"
    assert File.exists?(Path.join(out, "fake.provenance.json"))
    assert File.exists?(Path.join(out, "fake.spec_lint.json"))
    assert File.exists?(Path.join(out, "fake.spec_lint.log"))
    assert Path.join(checkout, "_build/test/lib/fake/ebin/Dummy.beam") |> File.exists?()
  end

  test "corpus runner reads a separate corpus build root and writes it as $BUILD", %{
    tmp_dir: dir
  } do
    {_checkout, revision, bin} = setup_mock_corpus(dir)
    manifest = Path.join(dir, "manifest.json")
    out = Path.join(dir, "reports")
    File.write!(manifest, JSON.encode!(%{"fake" => %{"revision" => revision}}))
    build = Path.join(dir, "build")

    for app <- ["fake", "dep"] do
      ebin = Path.join([build, "fake", "lib", app, "ebin"])
      File.mkdir_p!(ebin)
      File.write!(Path.join(ebin, "#{app}.beam"), app)
    end

    env = [{"SPEC_LINT_CORPUS_BUILD", build} | corpus_env(dir, manifest, out, bin)]
    {message, 2} = System.cmd("bash", [@runner, "fake"], env: env, stderr_to_stdout: true)
    assert message =~ "incomplete product run for fake"

    provenance = out |> Path.join("fake.provenance.json") |> File.read!() |> JSON.decode!()

    assert Enum.map(provenance["artifacts"], & &1["path"]) == [
             "$BUILD/fake/lib/fake/ebin",
             "$BUILD/fake/lib/dep/ebin",
             "$BUILD/fake/lib/fake/ebin"
           ]
  end

  test "corpus runner rejects unexpected source revisions by default", %{tmp_dir: dir} do
    {_checkout, _revision, bin} = setup_mock_corpus(dir)
    manifest = Path.join(dir, "manifest.json")
    File.write!(manifest, JSON.encode!(%{"fake" => %{"revision" => String.duplicate("0", 40)}}))

    {message, 2} =
      System.cmd("bash", [@runner, "fake"],
        env: corpus_env(dir, manifest, Path.join(dir, "reports"), bin),
        stderr_to_stdout: true
      )

    assert message =~ "unexpected revision for fake"
  end

  test "corpus runner measures the product run and fails when a budget is exceeded", %{
    tmp_dir: dir
  } do
    {_checkout, revision, bin} = setup_mock_corpus(dir)
    manifest = Path.join(dir, "manifest.json")
    out = Path.join(dir, "reports")
    File.write!(manifest, JSON.encode!(%{"fake" => %{"revision" => revision}}))
    budgets = Path.join(dir, "budgets.json")

    env =
      [
        {"MOCK_COMPLETION", "complete"},
        {"MOCK_EXIT", "0"}
        | corpus_env(dir, manifest, out, bin, budgets)
      ]

    File.write!(
      budgets,
      JSON.encode!(%{"corpora" => %{"fake" => %{"wall_s" => 600, "max_rss_mb" => 100_000}}})
    )

    assert {_, 0} = System.cmd("bash", [@runner, "fake"], env: env, stderr_to_stdout: true)
    resources = out |> Path.join("fake.resources.json") |> File.read!() |> JSON.decode!()
    assert resources["schema"] == "spec_lint.corpus_resources/1"
    assert is_number(resources["wall_s"])
    assert resources["max_rss_bytes"] > 0
    assert resources["method"] =~ "/usr/bin/time"
    assert resources["budget"] == %{"wall_s" => 600, "max_rss_mb" => 100_000, "within" => true}

    # Every process has a resident set: a zero memory budget is exceeded.
    File.write!(
      budgets,
      JSON.encode!(%{"corpora" => %{"fake" => %{"wall_s" => 600, "max_rss_mb" => 0}}})
    )

    assert {message, 2} = System.cmd("bash", [@runner, "fake"], env: env, stderr_to_stdout: true)
    assert message =~ "budget exceeded for fake"
    assert message =~ "resource budgets exceeded: fake"
    assert File.exists?(Path.join(out, "fake.spec_lint.json"))
    resources = out |> Path.join("fake.resources.json") |> File.read!() |> JSON.decode!()
    assert resources["budget"]["within"] == false

    # A corpus without a budget fails before anything runs (Milestone 5
    # review: it used to be measured and silently not checked).
    File.write!(budgets, JSON.encode!(%{"corpora" => %{}}))
    assert {message, 2} = System.cmd("bash", [@runner, "fake"], env: env, stderr_to_stdout: true)
    assert message =~ "no budget for fake in #{budgets}"
    refute message =~ "== fake"

    # So does a budgets file that does not exist (a typo in the variable).
    missing =
      List.keystore(
        env,
        "SPEC_LINT_BUDGETS",
        0,
        {"SPEC_LINT_BUDGETS", Path.join(dir, "absent.json")}
      )

    assert {message, 2} =
             System.cmd("bash", [@runner, "fake"], env: missing, stderr_to_stdout: true)

    assert message =~ "budgets file not found"
    refute message =~ "== fake"

    # Only the explicit value "none" measures without checking.
    none = List.keystore(env, "SPEC_LINT_BUDGETS", 0, {"SPEC_LINT_BUDGETS", "none"})
    assert {_, 0} = System.cmd("bash", [@runner, "fake"], env: none, stderr_to_stdout: true)
    resources = out |> Path.join("fake.resources.json") |> File.read!() |> JSON.decode!()
    assert resources["budget"] == nil
  end

  test "corpus runner never keeps the report of a killed or inconsistent run as a result", %{
    tmp_dir: dir
  } do
    {_checkout, revision, bin} = setup_mock_corpus(dir)
    manifest = Path.join(dir, "manifest.json")
    out = Path.join(dir, "reports")
    base = Path.join(dir, "base")
    File.write!(manifest, JSON.encode!(%{"fake" => %{"revision" => revision}}))
    env = [{"MOCK_COMPLETION", "complete"} | corpus_env(dir, manifest, out, bin)]

    run = fn extra ->
      System.cmd("bash", [@runner, "fake"], env: extra ++ env, stderr_to_stdout: true)
    end

    report = Path.join(out, "fake.spec_lint.json")
    rejected = Path.join(out, "fake.spec_lint.rejected.json")

    # A clean run, kept as the comparison base.
    assert {_, 0} = run.([{"MOCK_EXIT", "0"}])
    File.mkdir_p!(base)
    File.cp!(report, Path.join(base, "fake.spec_lint.json"))

    # The VM is killed after its complete report was written: /usr/bin/time
    # exits 1, the status of gated findings, whatever the report says.
    for code <- ["0", "1"] do
      assert {message, 2} = run.([{"MOCK_EXIT", code}, {"MOCK_KILL", "1"}])
      assert message =~ "was killed by a signal"
      refute File.exists?(report)
      assert JSON.decode!(File.read!(rejected))["completion"]["status"] == "complete"
      refute File.exists?(Path.join(out, "fake.resources.json"))

      # The comparison sees no result for the corpus.
      {output, 2} = System.cmd("bash", quiet([@compare, out, base]))
      assert JSON.decode!(output)["incomplete"] == ["fake"]
    end

    # A complete report whose exit code is not the process's.
    assert {message, 2} = run.([{"MOCK_EXIT", "1"}, {"MOCK_REPORT_EXIT", "0"}])
    assert message =~ "exit status/report mismatch for fake: 1 vs 0"
    refute File.exists?(report)
    assert File.exists?(rejected)

    # The next good run replaces the rejected report.
    assert {_, 0} = run.([{"MOCK_EXIT", "0"}])
    assert File.exists?(report)
    refute File.exists?(rejected)
  end

  test "corpus runner removes an earlier run's outputs before running a corpus", %{tmp_dir: dir} do
    {_checkout, _revision, bin} = setup_mock_corpus(dir)
    manifest = Path.join(dir, "manifest.json")
    out = Path.join(dir, "reports")
    File.mkdir_p!(out)
    File.write!(manifest, JSON.encode!(%{"fake" => %{"revision" => String.duplicate("0", 40)}}))

    earlier = ~w(fake.spec_lint.json fake.provenance.json fake.resources.json fake.json)
    for file <- earlier, do: File.write!(Path.join(out, file), "{}")

    {message, 2} =
      System.cmd("bash", [@runner, "fake"],
        env: corpus_env(dir, manifest, out, bin),
        stderr_to_stdout: true
      )

    assert message =~ "unexpected revision for fake"
    for file <- earlier, do: refute(File.exists?(Path.join(out, file)), file)
  end

  test "compare_replay.sh treats a missing, truncated or incomplete report as a failure", %{
    tmp_dir: dir
  } do
    base = Path.join(dir, "base")
    new = Path.join(dir, "new")
    File.mkdir_p!(base)
    File.mkdir_p!(new)

    report = fn status, code ->
      JSON.encode!(%{
        "completion" => %{"status" => status, "exit_code" => code},
        "ledger" => %{"slices" => %{"compared" => 1}},
        "findings" => []
      })
    end

    for name <- ~w(a b c d),
        do: File.write!(Path.join(base, "#{name}.spec_lint.json"), report.("complete", 0))

    File.write!(Path.join(new, "a.spec_lint.json"), report.("complete", 0))

    compare = fn ->
      {output, status} = System.cmd("bash", quiet([@compare, new, base]))
      {JSON.decode!(output), status}
    end

    # b and c are missing (c has only its provenance), d is truncated.
    File.write!(Path.join(new, "c.provenance.json"), "{}")
    File.write!(Path.join(new, "d.spec_lint.json"), binary_part(report.("complete", 0), 0, 30))
    {summary, 2} = compare.()
    statuses = Map.new(summary["corpora"], &{&1["corpus"], &1["status"]})

    assert statuses == %{
             "a" => "complete",
             "b" => "missing",
             "c" => "missing",
             "d" => "unreadable"
           }

    assert summary["incomplete"] == ~w(b c d)
    refute summary["all_unchanged"]

    # A complete set is compared; an incomplete run is not.
    for name <- ~w(b c d),
        do: File.write!(Path.join(new, "#{name}.spec_lint.json"), report.("complete", 0))

    assert {%{"all_unchanged" => true, "incomplete" => []}, 0} = compare.()

    File.write!(Path.join(new, "b.spec_lint.json"), report.("incomplete", 2))
    {summary, 2} = compare.()
    assert summary["incomplete"] == ["b"]
    refute summary["all_unchanged"]

    # A corpus named only by the environment is expected too.
    File.write!(Path.join(new, "b.spec_lint.json"), report.("complete", 0))

    {output, 2} =
      System.cmd("bash", quiet([@compare, new, base]), env: [{"SPEC_LINT_EXPECTED_CORPORA", "e"}])

    assert JSON.decode!(output)["incomplete"] == ["e"]
  end

  test "gate_diff.sh marks gates new, changed, unchanged or removed", %{tmp_dir: dir} do
    base = Path.join(dir, "base")
    new = Path.join(dir, "new")
    File.mkdir_p!(base)
    File.mkdir_p!(new)

    gate = fn subject, fingerprint, extra ->
      Map.merge(
        %{
          "subject" => subject,
          "rule" => "SL001",
          "evidence" => "clause_conflict",
          "slice" => 0,
          "clause" => 1,
          "line" => 3,
          "gate" => true,
          "fingerprint" => fingerprint,
          "details" => [["spec", subject]],
          "data" => %{}
        },
        extra
      )
    end

    report = fn findings ->
      JSON.encode!(%{
        "adapter" => "a",
        "completion" => %{"status" => "complete", "exit_code" => 1},
        "ledger" => %{},
        "findings" => findings
      })
    end

    File.write!(
      Path.join(base, "c.spec_lint.json"),
      report.([
        gate.("M.same/1", "f1", %{}),
        gate.("M.moved/1", "f2", %{}),
        gate.("M.gone/1", "f3", %{}),
        gate.("M.data/1", "f4", %{})
      ])
    )

    File.write!(
      Path.join(new, "c.spec_lint.json"),
      report.([
        gate.("M.same/1", "f1", %{"details" => [["spec", "reprinted"]]}),
        gate.("M.moved/1", "f9", %{}),
        gate.("M.fresh/1", "f5", %{}),
        gate.("M.data/1", "f4", %{"data" => %{"source_clause" => 1}}),
        gate.("M.info/1", "f6", %{"gate" => false})
      ])
    )

    {output, 0} = System.cmd("bash", [@gate_diff, new, base])
    diff = JSON.decode!(output)
    statuses = Map.new(diff["gates"], &{&1["subject"], {&1["status"], &1["changes"]}})

    assert statuses == %{
             "M.same/1" => {"unchanged", []},
             "M.moved/1" => {"changed", ["fingerprint"]},
             "M.data/1" => {"changed", ["data"]},
             "M.fresh/1" => {"new", nil},
             "M.gone/1" => {"removed", nil}
           }

    assert diff["counts"] == %{"changed" => 2, "new" => 1, "removed" => 1, "unchanged" => 1}

    File.write!(Path.join(new, "c.spec_lint.json"), "{")
    assert {_, 2} = System.cmd("bash", quiet([@gate_diff, new, base]))
  end

  test "gate_diff.sh and compare_lines.sh fail on a missing or incomplete corpus report", %{
    tmp_dir: dir
  } do
    # Milestone 5 review: both walked only NEW_DIR's reports, so a corpus
    # whose run was killed dropped out of the gate list and of both totals.
    base = Path.join(dir, "base")
    new = Path.join(dir, "new")
    File.mkdir_p!(base)
    File.mkdir_p!(new)

    report = fn status ->
      JSON.encode!(%{
        "adapter" => "a",
        "completion" => %{"status" => status, "exit_code" => 1},
        "ledger" => %{"slices" => %{"compared" => 1}, "obligations" => %{}, "entries" => []},
        "findings" => [
          %{
            "subject" => "M.f/1",
            "rule" => "SL001",
            "evidence" => "clause_conflict",
            "slice" => 0,
            "clause" => 1,
            "line" => 1,
            "gate" => true,
            "fingerprint" => "f"
          }
        ]
      })
    end

    for name <- ~w(a b),
        dir <- [base, new],
        do: File.write!(Path.join(dir, "#{name}.spec_lint.json"), report.("complete"))

    assert {output, 0} = System.cmd("bash", [@gate_diff, new, base])
    assert JSON.decode!(output)["counts"] == %{"unchanged" => 2}
    assert {_, 0} = System.cmd("bash", quiet([@lines, new, base]))

    # b's run was killed: only its provenance is left in NEW_DIR.
    File.rm!(Path.join(new, "b.spec_lint.json"))
    File.write!(Path.join(new, "b.provenance.json"), "{}")
    assert {message, 2} = System.cmd("bash", [@gate_diff, new, base], stderr_to_stdout: true)
    assert message =~ "missing, unreadable or incomplete reports in #{new}: b"
    assert {message, 2} = System.cmd("bash", [@lines, new, base], stderr_to_stdout: true)
    assert message =~ "b.spec_lint.json"

    # Nothing of b at all in NEW_DIR: BASE_DIR still expects it.
    File.rm!(Path.join(new, "b.provenance.json"))
    assert {_, 2} = System.cmd("bash", quiet([@gate_diff, new, base]))
    assert {_, 2} = System.cmd("bash", quiet([@lines, new, base]))

    # An incomplete report is not compared either.
    File.write!(Path.join(new, "b.spec_lint.json"), report.("incomplete"))
    assert {_, 2} = System.cmd("bash", quiet([@gate_diff, new, base]))
    assert {_, 2} = System.cmd("bash", quiet([@lines, new, base]))

    # Directories that do not exist, or hold nothing, are errors, not empty lists.
    empty = Path.join(dir, "empty")
    File.mkdir_p!(empty)

    for script <- [@gate_diff, @lines, @compare],
        args <- [
          [Path.join(dir, "absent"), base],
          [empty, empty],
          [new, Path.join(dir, "absent")]
        ] do
      assert {_, 2} = System.cmd("bash", quiet([script | args])), inspect({script, args})
    end
  end

  test "budgets.json covers the fifteen corpora and both release campaigns are within it" do
    root = Path.expand("../..", __DIR__)
    budgets = root |> Path.join("bench/corpus/budgets.json") |> File.read!() |> JSON.decode!()

    corpora =
      ~w(stdlib jason decimal nimble_options mime plug ecto req broadway oban
         phoenix_live_view ash nx absinthe tesla)

    assert Enum.sort(Map.keys(budgets["corpora"])) == Enum.sort(corpora)

    for {_corpus, %{"wall_s" => wall, "max_rss_mb" => rss}} <- budgets["corpora"] do
      assert is_number(wall) and wall > 0 and is_number(rss) and rss > 0
    end

    measured = Path.wildcard(Path.join(root, "bench/corpus/reports/release-1/*/*.resources.json"))
    assert length(measured) == 3 * 2 * length(corpora)

    # Release campaign 2 was measured against the frozen budgets.
    checked = Path.wildcard(Path.join(root, "bench/corpus/reports/release-2/*/*.resources.json"))
    assert length(checked) == 3 * length(corpora)

    for file <- checked,
        do: assert(JSON.decode!(File.read!(file))["budget"]["within"] == true, file)

    measured = measured ++ checked

    for file <- measured do
      resources = file |> File.read!() |> JSON.decode!()
      budget = budgets["corpora"][resources["corpus"]]
      assert resources["wall_s"] <= budget["wall_s"], file
      assert resources["max_rss_bytes"] <= budget["max_rss_mb"] * 1_048_576, file
    end
  end

  # bash arguments that run a script with its standard error discarded.
  defp quiet(argv), do: ["-c", ~s(exec 2>/dev/null; exec bash "$@"), "bash" | argv]

  defp setup_mock_corpus(dir) do
    checkout = Path.join([dir, "oss", "fake"])
    ebin = Path.join(checkout, "_build/test/lib/fake/ebin")
    File.mkdir_p!(ebin)
    File.write!(Path.join(ebin, "Dummy.beam"), "fixture")
    File.write!(Path.join(checkout, "mix.lock"), "lock")
    assert {_, 0} = System.cmd("git", ["-C", checkout, "init", "-q"])
    assert {_, 0} = System.cmd("git", ["-C", checkout, "add", "mix.lock"])

    assert {_, 0} =
             System.cmd("git", [
               "-C",
               checkout,
               "-c",
               "user.name=Test",
               "-c",
               "user.email=test@example.invalid",
               "commit",
               "-qm",
               "pin"
             ])

    {revision, 0} = System.cmd("git", ["-C", checkout, "rev-parse", "HEAD"])
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)

    File.write!(Path.join(bin, "mix"), """
    #!/usr/bin/env bash
    if [ "$1" = compile ]; then exit 0; fi
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --out)
          cat >"$2" <<'JSON'
    {"label":"fake","adapter":"adapter","totals":{"functions":0},"functions":[]}
    JSON
          exit 0 ;;
        --output)
          cat >"$2" <<JSON
    {"adapter":"adapter","checker_version":"checker","findings":[],"ledger":{},"completion":{"status":"${MOCK_COMPLETION:-incomplete}","exit_code":${MOCK_REPORT_EXIT:-${MOCK_EXIT:-2}}}}
    JSON
          # A VM killed after its report's atomic write, before it exits.
          if [ -n "${MOCK_KILL:-}" ]; then kill -9 $$; fi
          exit "${MOCK_EXIT:-2}" ;;
      esac
      shift
    done
    exit 2
    """)

    File.chmod!(Path.join(bin, "mix"), 0o755)
    {checkout, String.trim(revision), bin}
  end

  # Budgets are off unless a test names a file: the mock corpus has no entry
  # in bench/corpus/budgets.json, which fails the runner.
  defp corpus_env(dir, manifest, out, bin, budgets \\ "none") do
    [
      {"SPEC_LINT_BUDGETS", budgets},
      {"PATH", bin <> ":" <> System.get_env("PATH")},
      {"SPEC_LINT_OSS", Path.join(dir, "oss")},
      {"SPEC_LINT_CORPUS_MANIFEST", manifest},
      {"SPEC_LINT_CORPUS_OUT", out}
    ]
  end
end
