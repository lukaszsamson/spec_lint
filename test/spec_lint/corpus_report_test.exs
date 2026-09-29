defmodule SpecLint.CorpusReportTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir
  @script Path.expand("../../bench/corpus/normalise_report.sh", __DIR__)
  @runner Path.expand("../../bench/corpus/run.sh", __DIR__)

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
          cat >"$2" <<'JSON'
    {"adapter":"adapter","checker_version":"checker","findings":[],"ledger":{},"completion":{"status":"incomplete","exit_code":2}}
    JSON
          exit 2 ;;
      esac
      shift
    done
    exit 2
    """)

    File.chmod!(Path.join(bin, "mix"), 0o755)
    {checkout, String.trim(revision), bin}
  end

  defp corpus_env(dir, manifest, out, bin) do
    [
      {"PATH", bin <> ":" <> System.get_env("PATH")},
      {"SPEC_LINT_OSS", Path.join(dir, "oss")},
      {"SPEC_LINT_CORPUS_MANIFEST", manifest},
      {"SPEC_LINT_CORPUS_OUT", out}
    ]
  end
end
