defmodule SpecLint.Integration.Release.UpgradeTest do
  # Milestone 5, upgrade workflows through the public Mix tasks, on a consumer
  # in a temporary directory with spec_lint as a path dependency.
  #
  #   (c) a compiler upgrade: the baseline written under one compiler, the
  #       project compiled and linted by another, the documented
  #       reconciliation, and one baseline file per compiler. Needs a second
  #       qualified compiler (`SPEC_LINT_OTHER_ELIXIR`, tag `:cross_compiler`;
  #       excluded without it): 1.20.4 under 1.21 and the reverse, or the
  #       other 1.21 build.
  #   (d) a SpecLint upgrade: baselines written by an earlier tool revision.
  #       The baseline format has no tool field (its `version` is the format
  #       version, still 1), so the earlier revision is simulated by editing
  #       the file the way earlier writers and later policy changes would
  #       leave it, and by a real earlier revision of this repository.
  use ExUnit.Case, async: false

  Code.require_file("release_helper.exs", __DIR__)

  alias SpecLint.ProjectFixture, as: Fixture
  alias SpecLint.Release.Consumer, as: C

  @moduletag :integration
  @moduletag :release
  @moduletag timeout: 900_000

  # The last revision before Milestone 3's review fixes: baseline.ex and the
  # fingerprint code are the ones of the release, the rest differs.
  @previous_revision "128e2af"

  @findings ~w(Consumer.Bad.shape/1 Consumer.Bad.size/1 Consumer.Bad.wrap/1)

  defp consumer(prefix, dep \\ C.path_dep()) do
    dir = C.create!(prefix, dep)
    on_exit(fn -> File.rm_rf!(dir) end)
    Fixture.write!(dir, "lib/bad.ex", C.bad_source())
    dir
  end

  describe "(c) compiler upgrade" do
    @tag :cross_compiler
    test "the baseline of one compiler is refused by the other, and reconciled" do
      other = C.other_bin() || flunk("set SPEC_LINT_OTHER_ELIXIR to another qualified compiler")
      {other_id, _checker} = C.identity(other)
      refute other_id == C.adapter_id()
      dir = consumer("upgrade-compiler")

      # The team's baseline under the running compiler, with reviewed
      # reasons.
      {_output, 0} = C.mix(dir, ["spec_lint.baseline"])

      for mfa <- @findings,
          do: annotate!(dir, mfa, %{"reason" => "reviewed #{mfa}", "owner" => "team"})

      {0, _json, _output} = C.lint(dir)
      before = File.read!(C.baseline_path(dir))
      before_fps = fingerprints(C.read_baseline!(dir))

      # The compiler upgrade: the other compiler compiles the project (it
      # recompiles it, announced) and refuses to apply the baseline.
      {status, json, output} = C.lint(dir, [], bin: other)
      assert output =~ "spec_lint: recompiling consumer with #{other_id}"
      assert status == 2, output
      assert json["adapter"] == other_id
      assert json["completion"]["exit_code"] == 2
      assert json["baseline"]["applied"] == false
      assert json["baseline"]["reason"] == "adapter_mismatch"

      assert [reason] = json["completion"]["reasons"]

      assert reason =~
               "was written by adapter #{C.adapter_id()}, the current adapter is #{other_id}"

      assert reason =~ "review and regenerate it with mix spec_lint.baseline"

      # Outside CI it is a note and exit 0; the file is never touched.
      {output, 0} = C.mix(dir, ["spec_lint"], bin: other)
      assert output =~ "NOT applied: written by adapter #{C.adapter_id()}"
      assert File.read!(C.baseline_path(dir)) == before

      # Reconciliation, step 1: regenerate under the new compiler, review
      # the diff. Entries keep their reason and owner when the fingerprint is
      # the same on both compilers.
      {output, 0} = C.mix(dir, ["spec_lint.baseline"], bin: other)
      assert output =~ "3 finding(s)"
      regenerated = C.read_baseline!(dir)
      assert regenerated["adapter"] == other_id
      assert Enum.all?(regenerated["findings"], &(&1["adapter"] == other_id))
      after_fps = fingerprints(regenerated)

      for mfa <- @findings do
        entry = entry!(dir, mfa)

        if before_fps[mfa] == after_fps[mfa] do
          assert entry["reason"] == "reviewed #{mfa}"
          assert entry["owner"] == "team"
        else
          # The fingerprint is the key of what carries over: an entry whose
          # fingerprint changed starts without its reason.
          assert entry["reason"] == nil
          assert entry["owner"] == nil
        end
      end

      if C.other_line?(other) do
        # The lines encode map types differently: only the map spec changes.
        assert before_fps["Consumer.Bad.shape/1"] != after_fps["Consumer.Bad.shape/1"]
        assert before_fps["Consumer.Bad.size/1"] == after_fps["Consumer.Bad.size/1"]
        assert before_fps["Consumer.Bad.wrap/1"] == after_fps["Consumer.Bad.wrap/1"]
      end

      # Step 2: carry the lost reasons over by function, then commit.
      for mfa <- @findings, entry!(dir, mfa)["reason"] == nil do
        annotate!(dir, mfa, %{"reason" => "reviewed #{mfa}", "owner" => "team"})
      end

      {status, json, output} = C.lint(dir, [], bin: other)
      assert status == 0, output
      assert json["baseline"]["baselined"] == 3

      # One baseline cannot serve both compilers: the first one refuses it.
      {status, json, output} = C.lint(dir)
      assert status == 2, output
      assert json["baseline"]["reason"] == "adapter_mismatch"
      assert hd(json["completion"]["reasons"]) =~ "was written by adapter #{other_id}"

      # A baseline file per compiler, chosen on the command line, works
      # for both in any order and never asks for reconciliation.
      mine = "baselines/#{C.adapter_id()}.json"
      theirs = "baselines/#{other_id}.json"
      {_output, 0} = C.mix(dir, ["spec_lint.baseline", "--output", mine])
      {_output, 0} = C.mix(dir, ["spec_lint.baseline", "--output", theirs], bin: other)
      assert C.read_baseline!(dir, Path.join(dir, mine))["adapter"] == C.adapter_id()
      assert C.read_baseline!(dir, Path.join(dir, theirs))["adapter"] == other_id

      for _round <- 1..2 do
        {status, json, output} = C.lint(dir, ["--baseline", mine])
        assert status == 0, output
        assert json["baseline"]["baselined"] == 3

        {status, json, output} = C.lint(dir, ["--baseline", theirs], bin: other)
        assert status == 0, output
        assert json["baseline"]["baselined"] == 3
      end

      # The wrong file is refused whichever compiler reads it.
      {status, json, output} = C.lint(dir, ["--baseline", theirs])
      assert status == 2, output
      assert hd(json["completion"]["reasons"]) =~ "review and regenerate it"
    end

    @tag :cross_compiler
    test "entries kept for rules that did not run wait for reconciliation" do
      other = C.other_bin() || flunk("set SPEC_LINT_OTHER_ELIXIR to another qualified compiler")
      {other_id, _checker} = C.identity(other)
      dir = consumer("upgrade-pending")

      {_output, 0} = C.mix(dir, ["spec_lint.baseline"])

      # The other compiler regenerates with SL001 switched off: it cannot
      # recheck the entries, so it keeps them, marked, acknowledging nothing.
      Fixture.write!(dir, ".spec_lint.exs", "[rules: [SL001: :off]]\n")
      {_output, 0} = C.mix(dir, ["spec_lint.baseline"], bin: other)
      kept = C.read_baseline!(dir)
      assert kept["adapter"] == other_id
      assert length(kept["findings"]) == 3

      assert Enum.all?(kept["findings"], fn entry ->
               entry["pending_reconciliation"] == true and entry["adapter"] == C.adapter_id()
             end)

      # SL001 back on: the pending entries acknowledge nothing (three new
      # findings, exit 1, listed as pending); regenerating replaces them.
      File.rm!(Path.join(dir, ".spec_lint.exs"))
      {status, json, output} = C.lint(dir, [], bin: other)
      assert status == 1, output
      assert json["baseline"]["new"] == 3
      assert length(json["baseline"]["pending_reconciliation"]) == 3

      {_output, 0} = C.mix(dir, ["spec_lint.baseline"], bin: other)
      reconciled = C.read_baseline!(dir)

      assert Enum.all?(reconciled["findings"], fn entry ->
               entry["adapter"] == other_id and not Map.has_key?(entry, "pending_reconciliation")
             end)

      {0, json, _output} = C.lint(dir, [], bin: other)
      assert json["baseline"]["pending_reconciliation"] == []
    end
  end

  describe "(d) SpecLint upgrade" do
    # The baseline of a project with three gated findings, reviewed.
    defp baselined!(prefix) do
      dir = consumer(prefix)
      {_output, 0} = C.mix(dir, ["spec_lint.baseline"])

      for mfa <- @findings do
        annotate!(dir, mfa, %{
          "reason" => "reviewed #{mfa}",
          "owner" => "team",
          "expires" => "2999-12-31"
        })
      end

      {0, _json, _output} = C.lint(dir)
      dir
    end

    test "a baseline with fields a newer writer adds is applied, and regenerated in the current shape" do
      dir = baselined!("upgrade-tool-fields")
      current = C.read_baseline!(dir)

      # What an earlier writer left out (`blocked`, the entry-level
      # `adapter`) and a field a later one may add.
      legacy = %{
        "tool" => %{"name" => "spec_lint", "version" => "0.0.9"},
        "version" => 1,
        "adapter" => current["adapter"],
        "findings" => Enum.map(current["findings"], &Map.drop(&1, ["blocked", "adapter"])),
        "inventory" => current["inventory"]
      }

      C.write_baseline!(dir, legacy)

      # Applied as written: an entry without `blocked` acknowledges as before,
      # one without `adapter` inherits the file's.
      {status, json, output} = C.lint(dir)
      assert status == 0, output
      assert json["baseline"]["baselined"] == 3
      assert json["baseline"]["gate_changed"] == []
      assert json["baseline"]["pending_reconciliation"] == []

      # Reconciliation: regenerate. Reasons, owners and expiry dates
      # survive; the entries get their `blocked` and `adapter`; unknown
      # top-level fields are dropped.
      {_output, 0} = C.mix(dir, ["spec_lint.baseline"])
      regenerated = C.read_baseline!(dir)

      assert Map.keys(regenerated) |> Enum.sort() == [
               "adapter",
               "findings",
               "inventory",
               "version"
             ]

      for mfa <- @findings do
        assert %{
                 "reason" => reason,
                 "owner" => "team",
                 "expires" => "2999-12-31",
                 "blocked" => [],
                 "adapter" => adapter
               } = entry!(dir, mfa)

        assert reason == "reviewed #{mfa}"
        assert adapter == C.adapter_id()
      end

      assert regenerated == current
    end

    test "a baseline whose fingerprints changed is new findings plus stale entries, until regenerated" do
      dir = baselined!("upgrade-tool-fingerprints")
      current = C.read_baseline!(dir)

      # An earlier revision hashed the evidence differently: every
      # fingerprint is another one.
      changed =
        Map.update!(current, "findings", fn findings ->
          for entry <- findings,
              do: %{entry | "fingerprint" => "sha256:" <> String.duplicate("ab", 32)}
        end)

      C.write_baseline!(dir, changed)
      {status, json, output} = C.lint(dir)
      assert status == 1, output
      assert json["baseline"]["new"] == 3
      assert json["baseline"]["baselined"] == 0
      assert length(json["baseline"]["stale_findings"]) == 3

      # Reconciliation: review that the findings are the ones acknowledged
      # (same functions), regenerate, and carry reason, owner and expiry over
      # by function: entries are matched by fingerprint, so the regenerated
      # ones start without them.
      {_output, 0} = C.mix(dir, ["spec_lint.baseline"])

      for mfa <- @findings do
        assert %{"reason" => nil, "owner" => nil, "expires" => nil} = entry!(dir, mfa)
      end

      for entry <- current["findings"] do
        annotate!(dir, entry["mfa"], Map.take(entry, ["reason", "owner", "expires"]))
      end

      {status, json, output} = C.lint(dir)
      assert status == 0, output
      assert json["baseline"]["baselined"] == 3
      assert fingerprints(C.read_baseline!(dir)) == fingerprints(current)
    end

    test "an entry acknowledged while a gate prerequisite was blocked counts as new once it gates" do
      dir = baselined!("upgrade-tool-gate")

      # An earlier revision reported this finding as blocked by an overlap.
      baseline = C.read_baseline!(dir)

      findings =
        for entry <- baseline["findings"] do
          if entry["mfa"] == "Consumer.Bad.size/1",
            do: %{entry | "blocked" => ["no_overlap"]},
            else: entry
        end

      C.write_baseline!(dir, %{baseline | "findings" => findings})

      {status, json, output} = C.lint(dir)
      assert status == 1, output
      assert json["baseline"]["baselined"] == 2
      assert [%{"mfa" => "Consumer.Bad.size/1"}] = json["baseline"]["gate_changed"]

      assert [%{"subject" => "Consumer.Bad.size/1"}] =
               Enum.filter(json["findings"], & &1["blocking"])

      # Reconciliation: regenerate; the entry now records that it gates.
      {_output, 0} = C.mix(dir, ["spec_lint.baseline"])
      assert entry!(dir, "Consumer.Bad.size/1")["blocked"] == []
      assert entry!(dir, "Consumer.Bad.size/1")["reason"] == "reviewed Consumer.Bad.size/1"
      {0, _json, _output} = C.lint(dir)
    end

    test "a baseline from a newer format is refused by both tasks, and never overwritten" do
      dir = baselined!("upgrade-tool-format")
      future = dir |> C.read_baseline!() |> Map.put("version", 2)
      C.write_baseline!(dir, future)
      contents = File.read!(C.baseline_path(dir))

      {output, 2} = C.mix(dir, ["spec_lint", "--ci"])
      assert output =~ "unsupported baseline version 2"

      {output, 2} = C.mix(dir, ["spec_lint.baseline"])
      assert output =~ "unsupported baseline version 2"
      assert File.read!(C.baseline_path(dir)) == contents

      # Reconciliation: keep the file for reference, write a new baseline
      # (its reasons are copied over by hand).
      File.rename!(C.baseline_path(dir), Path.join(dir, "baseline.v2.json"))
      {_output, 0} = C.mix(dir, ["spec_lint.baseline"])
      assert C.read_baseline!(dir)["version"] == 1
      {0, _json, _output} = C.lint(dir)
    end

    @tag skip:
           if(C.revision_available?(@previous_revision),
             do: false,
             else: "revision #{@previous_revision} is not in this checkout"
           )
    test "a baseline written by an earlier revision of this repository is applied by the current one" do
      tool = Fixture.tmp_dir!("previous-revision")
      on_exit(fn -> File.rm_rf!(tool) end)
      :ok = C.extract_revision(@previous_revision, tool)

      dir = consumer("upgrade-tool-revision", C.path_dep(tool))
      {output, 0} = C.mix(dir, ["spec_lint.baseline"])
      assert output =~ "3 finding(s)"
      {0, _json, _output} = C.lint(dir)
      previous = C.read_baseline!(dir)
      for mfa <- @findings, do: annotate!(dir, mfa, %{"reason" => "reviewed #{mfa}"})

      # Upgrade the tool in place, as `git pull` or `mix deps.update` would:
      # the dependency's sources change, the consumer's do not.
      File.rm_rf!(tool)
      File.mkdir_p!(tool)

      for path <- ~w(lib mix.exs mix.lock),
          do: File.cp_r!(Path.join(Fixture.root(), path), Path.join(tool, path))

      {_output, 0} = C.mix(dir, ["deps.compile", "spec_lint", "--force"])

      {status, json, output} = C.lint(dir)
      assert status == 0, output
      assert json["baseline"]["baselined"] == 3
      assert json["baseline"]["stale_findings"] == []
      assert fingerprints(C.read_baseline!(dir)) == fingerprints(previous)

      # Regenerating with the new tool changes no fingerprint, and the
      # reasons stay.
      {_output, 0} = C.mix(dir, ["spec_lint.baseline"])
      assert fingerprints(C.read_baseline!(dir)) == fingerprints(previous)
      assert entry!(dir, "Consumer.Bad.size/1")["reason"] == "reviewed Consumer.Bad.size/1"
    end
  end

  ## Helpers

  defp fingerprints(baseline),
    do: Map.new(baseline["findings"], &{&1["mfa"], &1["fingerprint"]})

  defp entry!(dir, mfa) do
    dir |> C.read_baseline!() |> Map.fetch!("findings") |> Enum.find(&(&1["mfa"] == mfa)) ||
      flunk("no baseline entry for #{mfa}")
  end

  defp annotate!(dir, mfa, fields) do
    baseline = C.read_baseline!(dir)

    findings =
      for entry <- baseline["findings"],
          do: if(entry["mfa"] == mfa, do: Map.merge(entry, fields), else: entry)

    C.write_baseline!(dir, %{baseline | "findings" => findings})
  end
end
