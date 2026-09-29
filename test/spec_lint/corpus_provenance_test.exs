defmodule SpecLint.CorpusProvenanceTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir
  @root Path.expand("../..", __DIR__)
  @reduce Path.join(@root, "bench/corpus/reduce_body_report.jq")
  @provenance Path.join(@root, "bench/corpus/provenance.sh")

  test "body report reduction retains gate, candidate and reported evidence", %{tmp_dir: dir} do
    input = Path.join(dir, "body.json")

    rows = [
      row("unchanged", false, false, false),
      row("reported", false, false, true),
      row("candidate", false, true, true),
      row("gate", true, false, true)
    ]

    File.write!(input, JSON.encode!(%{"functions" => rows}))

    {json, 0} = System.cmd("jq", ["-f", @reduce, input])
    reduced = JSON.decode!(json)

    assert Enum.map(reduced["functions"], & &1["mfa"]) == ["reported", "candidate", "gate"]

    assert Enum.map(reduced["function_rows"], & &1["mfa"]) ==
             ["unchanged", "reported", "candidate", "gate"]

    assert Enum.find(reduced["function_rows"], &(&1["mfa"] == "reported"))["reported"] ==
             %{"body" => true, "signature" => false}

    assert Enum.find(reduced["function_rows"], &(&1["mfa"] == "candidate"))["candidate"] ==
             %{"body" => true, "signature" => false}

    assert Enum.find(reduced["function_rows"], &(&1["mfa"] == "gate"))["gate"] ==
             %{"body" => true, "signature" => false}
  end

  test "generated corpus JSON does not change the tool source hash", %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    ebin = Path.join(dir, "ebin")
    out1 = Path.join(dir, "first.json")
    out2 = Path.join(dir, "second.json")
    generated = Path.join(repo, "bench/corpus/precision_ceiling.json")

    File.mkdir_p!(Path.dirname(generated))
    File.mkdir_p!(Path.join(repo, "lib"))
    File.mkdir_p!(ebin)
    File.write!(Path.join(repo, "lib/tool.ex"), "defmodule Tool, do: nil\n")
    File.write!(Path.join(ebin, "Dummy.beam"), "beam")
    File.write!(generated, ~s({"result":1}))

    assert {_, 0} = System.cmd("git", ["-C", repo, "init", "-q"])
    assert {_, 0} = System.cmd("git", ["-C", repo, "add", "lib", "bench"])

    assert {_, 0} =
             System.cmd("git", [
               "-C",
               repo,
               "-c",
               "user.name=Test",
               "-c",
               "user.email=test@example.invalid",
               "commit",
               "-qm",
               "pin"
             ])

    assert {_, 0} = System.cmd("bash", [@provenance, out1, "fixture", repo, repo, repo, ebin])
    File.write!(generated, ~s({"result":2}))
    assert {_, 0} = System.cmd("bash", [@provenance, out2, "fixture", repo, repo, repo, ebin])

    first = out1 |> File.read!() |> JSON.decode!()
    second = out2 |> File.read!() |> JSON.decode!()
    assert first["tool"]["source_sha256"] == second["tool"]["source_sha256"]
    assert second["tool"]["dirty"]
  end

  defp row(mfa, gate?, candidate?, reported?) do
    %{
      "mfa" => mfa,
      "class" => %{"signature" => "unknown", "body" => "unknown"},
      "warn" => %{"signature" => false, "body" => false},
      "gate" => %{"signature" => false, "body" => gate?},
      "candidate" => %{"signature" => false, "body" => candidate?},
      "reported" => %{"signature" => false, "body" => reported?},
      "sampled" => false,
      "omission" => nil,
      "slices" => [%{"extra_warnings" => []}]
    }
  end
end
