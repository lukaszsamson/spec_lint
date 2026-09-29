defmodule SpecLint.Integration.BuildRecordTest do
  # Artifacts of another compiler build, through the public Mix tasks
  # (Milestone 2 review). Both qualified builds are 1.21.0-dev with checker
  # chunk v10, so Mix never recompiles when the compiler changes; before the
  # build record, `mix spec_lint --ci` analysed the other build's BEAM files
  # and reported that build's verdict under the running adapter's id (exit
  # 0 where the running build gates, and the reverse).
  #
  # The cross-compiler test runs only when SPEC_LINT_OTHER_ELIXIR names the
  # bin directory of the other qualified build.
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 600_000

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
       %{dir: dir} do
    case System.get_env("SPEC_LINT_OTHER_ELIXIR") do
      nil ->
        :ok

      other_bin ->
        other = fn args ->
          System.cmd(Path.join(other_bin, "mix"), args,
            cd: dir,
            env: Fixture.env([{"PATH", other_bin <> ":" <> System.get_env("PATH")}]),
            stderr_to_stdout: true
          )
        end

        {other_version, 0} =
          System.cmd(Path.join(other_bin, "elixir"), [
            "-e",
            "IO.write(System.build_info()[:revision])"
          ])

        refute String.starts_with?(other_version, running_revision())

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
        assert other_json["adapter"] == "1.21.0-dev+" <> String.slice(other_version, 0, 7)
        assert other_status == if(other_json["findings"] == [], do: 0, else: 1)
        refute other_json["artifacts"]["build_digest"] == json["artifacts"]["build_digest"]

        {status, json, output} = Fixture.lint(dir)
        assert output =~ "recompiling consumer", output
        assert_native_verdict(status, json, output)
    end
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
    end
  end

  defp running_revision, do: String.slice(System.build_info()[:revision], 0, 7)
  defp adapter_id, do: "#{System.version()}+#{running_revision()}"
  defp read(record), do: record |> File.read!() |> JSON.decode!()
end
