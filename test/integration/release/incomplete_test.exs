defmodule SpecLint.Integration.Release.IncompleteTest do
  # Milestone 5 (f): a compiler mismatch and an incomplete build, through the
  # public Mix tasks. An unusable input is exit 2, never "no finding", and
  # every state has a documented way out.
  #
  # The tests that need another compiler are excluded without one:
  # `SPEC_LINT_OTHER_ELIXIR` (tag `:cross_compiler`, another qualified
  # compiler) and `SPEC_LINT_UNSUPPORTED_ELIXIR` (skipped, the bin directory
  # of a compiler outside the support range, such as 1.19).
  use ExUnit.Case, async: false

  Code.require_file("release_helper.exs", __DIR__)

  alias SpecLint.ProjectFixture, as: Fixture
  alias SpecLint.Release.Consumer, as: C

  @moduletag :integration
  @moduletag :release
  @moduletag timeout: 900_000

  defp consumer(prefix) do
    dir = C.create!(prefix, C.path_dep())
    on_exit(fn -> File.rm_rf!(dir) end)
    Fixture.write!(dir, "lib/bad.ex", C.bad_source())
    dir
  end

  defp ebin(dir), do: Path.join(dir, "_build/dev/lib/consumer/ebin")

  describe "incomplete builds" do
    test "BEAM files that vanished from a build Mix believes complete" do
      dir = consumer("incomplete-beam")
      {_output, 0} = C.mix(dir, ["spec_lint.baseline"])
      {0, _json, _output} = C.lint(dir)

      File.rm!(Path.join(ebin(dir), "Elixir.Consumer.Bad.beam"))

      # Not a smaller project: exit 2 in both modes and for the baseline
      # task, which does not rewrite the file from a partial view.
      baseline = File.read!(C.baseline_path(dir))

      for args <- [["spec_lint"], ["spec_lint", "--ci"], ["spec_lint.baseline"]] do
        {output, 2} = C.mix(dir, args)
        assert output =~ "incomplete build: modules the build lists have no BEAM file"
        assert output =~ "Consumer.Bad"
        assert output =~ "recompile with mix compile --force"
      end

      assert File.read!(C.baseline_path(dir)) == baseline

      # The documented way out.
      {_output, 0} = C.mix(dir, ["compile", "--force"])
      {status, json, output} = C.lint(dir)
      assert status == 0, output
      assert json["baseline"]["baselined"] == 3
    end

    test "a removed build directory" do
      dir = consumer("incomplete-ebin")
      {_status, _json, _output} = C.lint(dir)

      File.rm_rf!(ebin(dir))
      {output, 2} = C.mix(dir, ["spec_lint", "--ci"])
      assert output =~ "incomplete build"
      assert output =~ "recompile with mix compile --force"

      {_output, 0} = C.mix(dir, ["compile", "--force"])
      {1, json, _output} = C.lint(dir)
      assert length(json["findings"]) == 3
    end

    test "BEAM files changed after the build was recorded are rebuilt, not analysed" do
      dir = consumer("incomplete-changed")
      {1, _json, _output} = C.lint(dir)
      File.write!(Path.join(ebin(dir), "Elixir.Consumer.beam"), "not a beam file")

      {status, json, output} = C.lint(dir)

      assert output =~
               "spec_lint: recompiling consumer with #{C.adapter_id()}: BEAM files changed"

      assert status == 1, output
      assert length(json["findings"]) == 3
    end

    test "a project that does not compile" do
      dir = consumer("incomplete-compile")
      Fixture.write!(dir, "lib/broken.ex", "defmodule Broken do\n  def x(\n")

      for args <- [["spec_lint"], ["spec_lint", "--ci"], ["spec_lint.baseline"]] do
        {output, 2} = C.mix(dir, args)
        assert output =~ "compilation failed; spec_lint needs a compiled project"
      end

      refute File.exists?(C.baseline_path(dir))

      File.rm!(Path.join(dir, "lib/broken.ex"))
      {1, _json, _output} = C.lint(dir)
    end

    test "invalid options and configuration fail before anything is compiled" do
      dir = consumer("incomplete-options")

      {output, 2} = C.mix(dir, ["spec_lint", "--ci", "--profile", "loose"])
      assert output =~ "--profile must be soundness or review"
      refute File.exists?(Path.join(dir, "_build/dev/lib/consumer")), "no compilation happened"

      Fixture.write!(dir, ".spec_lint.exs", "[unknown_key: true]\n")
      {output, 2} = C.mix(dir, ["spec_lint", "--ci"])
      assert output =~ "unknown_key"
    end
  end

  describe "compiler mismatch" do
    @tag :cross_compiler
    test "a project compiled by the other compiler is rebuilt by both tasks, never analysed as it is" do
      other = C.other_bin() || flunk("set SPEC_LINT_OTHER_ELIXIR to another qualified compiler")
      {other_id, other_checker} = C.identity(other)
      dir = consumer("mismatch-rebuild")

      {_output, 0} = C.mix(dir, ["compile"], bin: other)
      record = Path.join(dir, "_build/dev/lib/consumer/.mix/spec_lint.build")
      refute File.exists?(record)

      # The lint task rebuilds it with the running compiler.
      {status, json, output} = C.lint(dir)
      assert output =~ "spec_lint: recompiling consumer with #{C.adapter_id()}"
      assert json["adapter"] == C.adapter_id()
      assert status == 1, output
      assert length(json["findings"]) == 3

      # And back: the other compiler's run rebuilds what this one built, and
      # reports under its own adapter.
      {output, other_status} =
        C.mix(dir, ["spec_lint", "--ci", "--format", "json", "--output", "other.json"],
          bin: other
        )

      assert output =~ "spec_lint: recompiling consumer with #{other_id}: compiled by another"
      assert other_status == 1
      other_json = dir |> Path.join("other.json") |> File.read!() |> JSON.decode!()
      assert other_json["adapter"] == other_id
      assert other_json["checker_version"] == other_checker

      # The baseline task rebuilds too, and records its own adapter.
      {output, 0} = C.mix(dir, ["spec_lint.baseline"])
      assert output =~ "spec_lint: recompiling consumer with #{C.adapter_id()}"
      assert C.read_baseline!(dir)["adapter"] == C.adapter_id()
    end

    if is_nil(C.unsupported_bin()) do
      @tag skip: "set SPEC_LINT_UNSUPPORTED_ELIXIR to the bin directory of a 1.19 compiler"
    end

    test "a compiler outside the support range is refused" do
      bin = C.unsupported_bin()
      dir = consumer("mismatch-unsupported")

      # A dependency's Elixir requirement is only a warning to Mix, so the
      # task starts and refuses itself: exit 2 in CI, and never a verdict.
      {output, 2} = C.mix(dir, ["spec_lint", "--ci"], bin: bin)
      assert output =~ ~s(the dependency :spec_lint requires Elixir "~> 1.20.4 or ~> 1.21-dev")
      assert output =~ "unsupported compiler"
      assert output =~ "Result: incomplete, exit 2"

      # Outside CI it says so and exits 0: the run is incomplete, not clean.
      {output, 0} = C.mix(dir, ["spec_lint"], bin: bin)
      assert output =~ "unsupported compiler"
      assert output =~ "Result: incomplete, exit 0"

      # No baseline can be written from it.
      {output, 2} = C.mix(dir, ["spec_lint.baseline"], bin: bin)
      assert output =~ "unsupported compiler"
      refute File.exists?(C.baseline_path(dir))
    end
  end
end
