defmodule SpecLint.Integration.BuildRecordTest do
  # Artifacts of another compiler build, through the public Mix tasks
  # (Milestone 2 review). Both qualified builds are 1.21.0-dev with checker
  # chunk v10, so Mix never recompiles when the compiler changes; before the
  # build record, `mix spec_lint --ci` analysed the other build's BEAM files
  # and reported that build's verdict under the running adapter's id (exit
  # 0 where the running build gates, and the reverse).
  #
  # The cross-compiler test runs only when SPEC_LINT_OTHER_ELIXIR names the
  # bin directory of another qualified compiler: the other 1.21 build
  # (Milestone 2), or the other compiler line, 1.20.4 under 1.21 and the
  # reverse (Milestone 3).
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 600_000

  alias SpecLint.{Config, Project, Run}
  alias SpecLint.ProjectFixture, as: Fixture

  # Audit row 19: correct under c24c235, gated (SL003) under 648b2a9, whose
  # checker stores a narrowed domain for `value`.
  @source """
  defmodule IntoProbe do
    @spec f(boolean(), atom()) :: atom()
    def f(flag, value) do
      into = if flag, do: [], else: ""
      _ = for _ <- [1], do: value, into: into
      value
    end
  end
  """

  setup do
    dir = Fixture.tmp_dir!("build-record")
    on_exit(fn -> File.rm_rf!(dir) end)

    Fixture.write!(dir, "mix.exs", """
    defmodule Consumer.MixProject do
      use Mix.Project

      def project do
        [
          app: :consumer,
          version: "0.1.0",
          deps: [{:spec_lint, path: #{inspect(Fixture.root())}, only: [:dev, :test], runtime: false}]
        ]
      end
    end
    """)

    Fixture.write!(dir, "lib/into_probe.ex", @source)
    %{dir: dir, record: Path.join(dir, "_build/dev/lib/consumer/.mix/spec_lint.build")}
  end

  test "the Mix tasks recompile a build they did not record or another build recorded",
       %{dir: dir, record: record} do
    {output, 0} = Fixture.mix(dir, ["compile"])
    refute File.exists?(record), output
    adapter = adapter_id()

    # Compiled by plain `mix compile`: the producer is unknown.
    {status, json, output} = Fixture.lint(dir)
    assert output =~ "spec_lint: recompiling consumer with #{adapter}: no record of the"
    assert_native_verdict(status, json, output)
    assert json["artifacts"]["recorded"] == ["consumer"]
    assert %{"adapter" => ^adapter, "beams" => %{"Elixir.IntoProbe.beam" => _}} = read(record)

    # Recorded by this build and unchanged: no recompilation.
    {status, json, output} = Fixture.lint(dir)
    refute output =~ "recompiling"
    assert_native_verdict(status, json, output)

    # Recorded by another build (its own `mix spec_lint`).
    File.write!(
      record,
      JSON.encode!(%{read(record) | "build_digest" => String.duplicate("0", 64)})
    )

    {status, json, output} = Fixture.lint(dir)
    assert output =~ "recompiling consumer with #{adapter}: compiled by another compiler build"
    assert_native_verdict(status, json, output)
    assert read(record)["build_digest"] == json["artifacts"]["build_digest"]

    # The baseline task compiles the same way.
    File.rm!(record)
    {output, 0} = Fixture.mix(dir, ["spec_lint.baseline"])
    assert output =~ "recompiling consumer"
    assert Fixture.baseline!(dir)["adapter"] == adapter
    assert File.exists?(record)
  end

  @tag :cross_compiler
  test "a build compiled by the other qualified compiler is rebuilt before it is analysed",
       %{dir: dir, record: record} do
    case System.get_env("SPEC_LINT_OTHER_ELIXIR") do
      nil ->
        :ok

      other_bin ->
        other = other_compiler(other_bin, dir)
        {other_id, other_checker} = other_identity(other_bin)
        refute String.ends_with?(other_id, "+" <> running_revision())

        # (a) compiled by the other build, linted by this one.
        {_output, 0} = other.(["compile"])
        {status, json, output} = Fixture.lint(dir)
        assert output =~ "recompiling consumer", output
        assert_native_verdict(status, json, output)

        # (b) the other build lints next: it rebuilds too, and reports its
        # own adapter; then this build again.
        {output, other_status} =
          other.(["spec_lint", "--ci", "--format", "json", "--output", "other.json"])

        assert output =~ "recompiling consumer", output
        other_json = dir |> Path.join("other.json") |> File.read!() |> JSON.decode!()
        assert other_json["adapter"] == other_id
        assert other_json["checker_version"] == other_checker
        assert other_status == if(other_json["findings"] == [], do: 0, else: 1)
        refute other_json["artifacts"]["build_digest"] == json["artifacts"]["build_digest"]
        assert JSON.decode!(File.read!(record))["adapter"] == other_id

        # (c) the other build's recorded artifacts, analysed without the
        # Mix task's recompilation (SpecLint.Run on the build directory):
        # refused, exit 2, naming the other compiler.
        assert {:error, message} = run_in_place(dir)
        assert message =~ "BEAM files not produced by the running compiler (#{adapter_id()})"

        if other_checker == running_checker() do
          assert message =~ "consumer: compiled by another compiler build (#{other_id}"
        else
          assert message =~
                   "consumer: compiled by another compiler line (#{other_id}, checker " <>
                     "#{other_checker}"
        end

        # (d) the same artifacts without a record (a plain `mix compile` by
        # the other compiler): another compiler line's chunks fail closed
        # (exit 2); another build of the same line cannot be told apart
        # without the record (DESIGN.md 5.2).
        File.rm!(record)

        if other_checker != running_checker() do
          assert {:ok, run} = run_in_place(dir)
          assert run.exit_code == 2
          assert run.completion == :incomplete
          assert [reason] = run.completion_reasons

          assert reason =~
                   "unsupported checker chunk in IntoProbe: version :#{other_checker}, " <>
                     "the running checker writes :#{running_checker()}"
        end

        {status, json, output} = Fixture.lint(dir)
        assert output =~ "recompiling consumer", output
        assert_native_verdict(status, json, output)
    end
  end

  defp other_compiler(other_bin, dir) do
    fn args ->
      System.cmd(Path.join(other_bin, "mix"), args,
        cd: dir,
        env: Fixture.env([{"PATH", other_bin <> ":" <> System.get_env("PATH")}]),
        stderr_to_stdout: true
      )
    end
  end

  # The other compiler's adapter id and checker chunk version.
  defp other_identity(other_bin) do
    {output, 0} =
      System.cmd(Path.join(other_bin, "elixir"), [
        "-e",
        ~S|IO.write("#{System.version()}+#{System.build_info()[:revision]} | <>
          ~S|#{:elixir_erl.checker_version()}")|
      ])

    [id, checker] = String.split(output, " ")
    {id, checker}
  end

  # SpecLint.Run on the consumer's build directory in this VM, without the
  # Mix task (so without its recompilation).
  defp run_in_place(dir) do
    ebin = Path.join(dir, "_build/dev/lib/consumer/ebin")
    project = Project.from_ebins([{:consumer, ebin}], dir)
    Run.execute(project, %Config{baseline: Path.join(dir, "none.json")}, ci: true)
  end

  # The verdict the running build gives on a build it compiled itself
  # (test/spec_lint/upstream_qualification_test.exs, audit row 19).
  defp assert_native_verdict(status, json, output) do
    assert json["adapter"] == adapter_id(), output

    case running_revision() do
      "c24c235" ->
        assert status == 0, output
        assert json["findings"] == []

      "648b2a9" ->
        assert status == 1, output
        assert [%{"rule" => "SL003", "blocking" => true}] = json["findings"]

      # Elixir 1.20.4 (Milestone 3): no narrowing, as on c24c235.
      "759443e" ->
        assert status == 0, output
        assert json["findings"] == []
    end
  end

  defp running_revision, do: String.slice(System.build_info()[:revision], 0, 7)
  defp running_checker, do: Atom.to_string(:elixir_erl.checker_version())
  defp adapter_id, do: "#{System.version()}+#{running_revision()}"
  defp read(record), do: record |> File.read!() |> JSON.decode!()
end
