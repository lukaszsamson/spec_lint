defmodule SpecLint.Integration.BuildAndCoverageTest do
  # Consumer integration for coverage, discovery and the baseline file, in
  # its own Mix project (a separate OS process, like
  # SpecLint.Integration.ConsumerTest):
  #
  #   * removing a @spec while keeping the exported function is a coverage
  #     regression in CI (exit 1), naming the function;
  #   * mix spec_lint.baseline --output reads the previous baseline from the
  #     file it writes, so the removal is acknowledged there;
  #   * a mistyped --baseline is a configuration error (exit 2);
  #   * an ebin whose BEAM files were deleted (with or without its .app
  #     file) is an error (exit 2), not zero specs: Mix does not rebuild it;
  #   * a project whose ebin exists but holds no module succeeds with
  #     "0 specs checked" (exit 0);
  #   * a missing ebin is an error (exit 2), not zero specs.
  use ExUnit.Case, async: false

  import SpecLint.ProjectFixture

  @moduletag :integration
  @moduletag timeout: 300_000

  @ebin "_build/dev/lib/consumer/ebin"

  @source """
  defmodule Consumer do
    @spec greet(atom()) :: String.t()
    def greet(name) when is_atom(name), do: "hello " <> Atom.to_string(name)
  end
  """

  setup_all do
    dir = tmp_dir!("coverage")
    on_exit(fn -> File.rm_rf!(dir) end)

    # CONSUMER_SKIP_COMPILE replaces `compile` with a no-op. The public
    # task must refuse this unsupported pipeline rather than accept no build.
    write!(dir, "mix.exs", """
    defmodule Consumer.MixProject do
      use Mix.Project

      def project do
        [
          app: :consumer,
          version: "0.1.0",
          aliases: aliases(),
          deps: [{:spec_lint, path: #{inspect(root())}, only: [:dev, :test], runtime: false}]
        ]
      end

      defp aliases do
        if System.get_env("CONSUMER_SKIP_COMPILE"), do: [compile: fn _ -> :ok end], else: []
      end
    end
    """)

    write!(dir, "lib/consumer.ex", @source)
    {output, status} = mix(dir, ["compile"])
    assert status == 0, output
    %{dir: dir}
  end

  test "spec removal, the baseline file, deleted BEAM files, an empty and a missing ebin",
       %{dir: dir} do
    # A baseline with one compared spec.
    {status, json, output} = lint(dir)
    assert status == 0, output
    assert json["ledger"]["slices"]["compared"] == 1
    {output, 0} = mix(dir, ["spec_lint.baseline"])
    assert output =~ "1 inventory entries"
    File.cp!(Path.join(dir, ".spec_lint_baseline.json"), Path.join(dir, "alt.json"))

    # A mistyped explicit baseline path: exit 2, never "no baseline".
    {status, _json, output} = lint(dir, ["--baseline", ".spec_lint_basline.json"])
    assert status == 2, output
    assert output =~ "baseline file not found: .spec_lint_basline.json"

    # The @spec is removed, the function kept: exit 1 in CI, SL008 names it.
    write!(dir, "lib/consumer.ex", """
    defmodule Consumer do
      def greet(name) when is_atom(name), do: "hello " <> Atom.to_string(name)
    end
    """)

    {status, json, output} = lint(dir)
    assert status == 1, output

    assert [
             %{
               "rule" => "SL008",
               "subject" => "Consumer.greet/1",
               "slice" => 0,
               "blocking" => true,
               "data" => %{
                 "status" => "unanalysed",
                 "reason" => "spec_removed",
                 "regression" => true
               }
             }
           ] = json["findings"]

    # With SL008 not selected it is a coverage violation naming the MFA.
    {status, json, output} = lint(dir, ["--except", "SL008"])
    assert status == 1, output
    assert [violation] = json["completion"]["coverage_violations"]
    assert violation =~ "Consumer.greet/1 slice 0 is unanalysed (spec_removed)"

    # mix spec_lint.baseline --output alt.json compares against alt.json
    # (not the configured baseline, gone here): the removal is written as an
    # acknowledged unanalysed entry, and alt.json accepts the run.
    File.rm!(Path.join(dir, ".spec_lint_baseline.json"))
    {status, _json, output} = lint(dir, ["--baseline", "alt.json"])
    assert status == 1, output
    {output, 0} = mix(dir, ["spec_lint.baseline", "--output", "alt.json"])
    assert output =~ "1 acknowledged"
    alt = dir |> Path.join("alt.json") |> File.read!() |> JSON.decode!()

    assert [%{"mfa" => "Consumer.greet/1", "status" => "unanalysed", "reason" => "spec_removed"}] =
             alt["inventory"]

    {status, json, output} = lint(dir, ["--baseline", "alt.json"])
    assert status == 0, output
    assert [%{"rule" => "SL008", "baseline" => "baselined"}] = json["findings"]

    # Deleting the function instead is not a regression.
    write!(dir, "lib/consumer.ex", """
    defmodule Consumer do
    end
    """)

    {status, json, output} = lint(dir, ["--baseline", "alt.json"])
    assert status == 0, output
    assert json["findings"] == []

    # BEAM files deleted from the ebin (or a partial _build restore): Mix
    # does not rebuild them, so this is exit 2, whether the .app file stays
    # (it lists the module) or goes too (the compile manifest lists it).
    write!(dir, "lib/consumer.ex", @source)
    {_output, 0} = mix(dir, ["compile"])
    {output, 0} = mix(dir, ["spec_lint.baseline"])
    assert output =~ "1 inventory entries"
    beam = Path.join([dir, @ebin, "Elixir.Consumer.beam"])

    File.rm!(beam)
    {output, status} = mix(dir, ["spec_lint", "--ci"])
    assert status == 2, output
    assert output =~ "incomplete build"
    assert output =~ "consumer (#{@ebin}): Consumer"
    refute output =~ "0 specs checked"

    File.rm!(Path.join([dir, @ebin, "consumer.app"]))
    {output, status} = mix(dir, ["spec_lint", "--ci"])
    assert status == 2, output
    assert output =~ "consumer (#{@ebin}): Consumer"

    {output, 0} = mix(dir, ["compile", "--force"])
    assert File.exists?(beam), output

    # An ebin with no module at all: 0 specs checked, exit 0.
    File.rm!(Path.join(dir, "lib/consumer.ex"))
    File.rm!(Path.join(dir, ".spec_lint_baseline.json"))
    {output, status} = mix(dir, ["spec_lint", "--ci"])
    assert status == 0, output
    assert output =~ "0 specs checked"
    assert output =~ "Result: complete, exit 0"
    assert File.dir?(Path.join(dir, @ebin))

    # A missing ebin with compile disabled: exit 2, never "0 specs".
    File.rm_rf!(Path.join(dir, @ebin))
    {output, status} = mix(dir, ["spec_lint", "--ci"], [{"CONSUMER_SKIP_COMPILE", "1"}])
    assert status == 2, output
    assert output =~ "unsupported compiler pipeline for consumer"
    assert output =~ "alias compile"
    refute output =~ "0 specs checked"
  end
end
