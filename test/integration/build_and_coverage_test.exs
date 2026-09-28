defmodule SpecLint.Integration.BuildAndCoverageTest do
  # Consumer integration for coverage and discovery, in its own Mix project
  # (a separate OS process, like SpecLint.Integration.ConsumerTest):
  #
  #   * removing a @spec while keeping the exported function is a coverage
  #     regression in CI (exit 1), naming the function;
  #   * a project whose ebin exists but holds no module succeeds with
  #     "0 specs checked" (exit 0);
  #   * a missing ebin is an error (exit 2), not zero specs.
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 300_000

  @root Path.expand("../..", __DIR__)

  setup_all do
    dir =
      Path.join([
        @root,
        "tmp/integration",
        "coverage-#{System.os_time(:millisecond)}-#{System.unique_integer([:positive])}"
      ])

    on_exit(fn -> File.rm_rf!(dir) end)
    File.mkdir_p!(Path.join(dir, "lib"))

    # CONSUMER_SKIP_COMPILE turns `compile` into a no-op, so a removed
    # build directory stays removed when mix spec_lint runs.
    File.write!(Path.join(dir, "mix.exs"), """
    defmodule Consumer.MixProject do
      use Mix.Project

      def project do
        [
          app: :consumer,
          version: "0.1.0",
          aliases: aliases(),
          deps: [{:spec_lint, path: #{inspect(@root)}, only: [:dev, :test], runtime: false}]
        ]
      end

      defp aliases do
        if System.get_env("CONSUMER_SKIP_COMPILE"), do: [compile: fn _ -> :ok end], else: []
      end
    end
    """)

    File.write!(Path.join(dir, "lib/consumer.ex"), """
    defmodule Consumer do
      @spec greet(atom()) :: String.t()
      def greet(name) when is_atom(name), do: "hello " <> Atom.to_string(name)
    end
    """)

    {output, status} = mix(dir, ["compile"])
    assert status == 0, output
    %{dir: dir}
  end

  defp mix(dir, args, env \\ []) do
    System.cmd(System.find_executable("mix"), args,
      cd: dir,
      env: [{"MIX_ENV", "dev"} | env],
      stderr_to_stdout: true
    )
  end

  defp lint(dir, extra \\ []) do
    report = Path.join(dir, "report.json")
    File.rm(report)

    {output, status} =
      mix(dir, ["spec_lint", "--ci", "--format", "json", "--output", report] ++ extra)

    json = if File.exists?(report), do: report |> File.read!() |> JSON.decode!()
    {status, json, output}
  end

  test "spec removal, an empty ebin and a missing ebin", %{dir: dir} do
    # A baseline with one compared spec.
    {status, json, output} = lint(dir)
    assert status == 0, output
    assert json["ledger"]["slices"]["compared"] == 1
    {output, 0} = mix(dir, ["spec_lint.baseline"])
    assert output =~ "1 inventory entries"

    # The @spec is removed, the function kept: exit 1 in CI, SL008 names it.
    File.write!(Path.join(dir, "lib/consumer.ex"), """
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

    # Deleting the function instead is not a regression.
    File.write!(Path.join(dir, "lib/consumer.ex"), """
    defmodule Consumer do
    end
    """)

    {status, json, output} = lint(dir)
    assert status == 0, output
    assert json["findings"] == []

    # An ebin with no module at all: 0 specs checked, exit 0.
    File.rm!(Path.join(dir, "lib/consumer.ex"))
    File.rm!(Path.join(dir, ".spec_lint_baseline.json"))
    {output, status} = mix(dir, ["spec_lint", "--ci"])
    assert status == 0, output
    assert output =~ "0 specs checked"
    assert output =~ "Result: complete, exit 0"
    assert File.dir?(Path.join(dir, "_build/dev/lib/consumer/ebin"))

    # A missing ebin: exit 2, never "0 specs".
    File.rm_rf!(Path.join(dir, "_build/dev/lib/consumer/ebin"))
    {output, status} = mix(dir, ["spec_lint", "--ci"], [{"CONSUMER_SKIP_COMPILE", "1"}])
    assert status == 2, output
    assert output =~ "missing build directory for consumer (_build/dev/lib/consumer/ebin)"
    refute output =~ "0 specs checked"
  end
end
