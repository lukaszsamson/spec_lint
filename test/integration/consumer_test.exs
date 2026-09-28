defmodule SpecLint.Integration.ConsumerTest do
  # Consumer integration (DESIGN.md section 10): a tiny Mix project with a
  # path dependency on spec_lint runs `mix spec_lint --ci --format json`
  # in a separate OS process. Exit codes and the JSON report are asserted
  # through the life of a project: clean, an injected SL001, a baseline
  # that suppresses it and then goes stale, an SL008 from a module compiled
  # without debug info, and its acknowledgement.
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 300_000

  @root Path.expand("../..", __DIR__)

  # One directory per test run, removed afterwards, so concurrent runs in
  # the same checkout do not share a fixture. The per-test helpers read it
  # from the process dictionary set in setup.
  setup_all do
    dir =
      Path.join([
        @root,
        "tmp/integration",
        "consumer-#{System.os_time(:millisecond)}-#{System.unique_integer([:positive])}"
      ])

    on_exit(fn -> File.rm_rf!(dir) end)
    File.mkdir_p!(Path.join(dir, "lib"))
    Process.put(:consumer_dir, dir)

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule Consumer.MixProject do
      use Mix.Project

      def project do
        [
          app: :consumer,
          version: "0.1.0",
          deps: [{:spec_lint, path: #{inspect(@root)}, only: [:dev, :test], runtime: false}]
        ]
      end
    end
    """)

    write("lib/consumer.ex", """
    defmodule Consumer do
      @spec greet(atom()) :: String.t()
      def greet(name) when is_atom(name), do: "hello " <> Atom.to_string(name)
    end
    """)

    {output, status} = mix(["compile"])
    assert status == 0, output
    %{dir: dir}
  end

  setup %{dir: dir} do
    Process.put(:consumer_dir, dir)
    :ok
  end

  defp dir, do: Process.get(:consumer_dir)

  defp write(path, contents), do: File.write!(Path.join(dir(), path), contents)

  defp mix(args) do
    System.cmd(System.find_executable("mix"), args,
      cd: dir(),
      env: [{"MIX_ENV", "dev"}],
      stderr_to_stdout: true
    )
  end

  defp lint(extra \\ []) do
    report = Path.join(dir(), "report.json")
    File.rm(report)
    {output, status} = mix(["spec_lint", "--ci", "--format", "json", "--output", report] ++ extra)
    json = if File.exists?(report), do: report |> File.read!() |> JSON.decode!()
    {status, json, output}
  end

  test "exit codes and JSON across a project's life" do
    # A clean project.
    {status, json, output} = lint()
    assert status == 0, output
    assert json["schema"] == "spec_lint/report"

    assert json["completion"] == %{
             "status" => "complete",
             "exit_code" => 0,
             "blocking" => 0,
             "coverage_violations" => [],
             "reasons" => []
           }

    assert json["findings"] == []
    assert json["project"]["mix_env"] == "dev"
    assert json["ledger"]["slices"]["compared"] == 1

    assert [
             %{
               "module" => "Consumer",
               "path" => "_build/dev/lib/consumer/ebin/Elixir.Consumer.beam"
             }
           ] =
             json["beams"]

    # Byte-identical output for an unchanged project.
    first = File.read!(Path.join(dir(), "report.json"))
    {0, _json, _} = lint()
    assert File.read!(Path.join(dir(), "report.json")) == first

    # An injected SL001: exit 1.
    write("lib/bad.ex", """
    defmodule Consumer.Bad do
      @spec size(atom()) :: integer()
      def size(name) when is_atom(name), do: name
    end
    """)

    {status, json, output} = lint()
    assert status == 1, output
    assert [finding] = json["findings"]

    assert %{
             "rule" => "SL001",
             "subject" => "Consumer.Bad.size/1",
             "evidence" => "conflict",
             "gate" => true,
             "baseline" => "new",
             "blocking" => true,
             "file" => "lib/bad.ex"
           } = finding

    # The baseline acknowledges it: exit 0.
    {output, 0} = mix(["spec_lint.baseline"])
    assert output =~ "1 finding(s)"
    baseline = dir() |> Path.join(".spec_lint_baseline.json") |> File.read!() |> JSON.decode!()
    assert [%{"fingerprint" => fingerprint, "rule" => "SL001"}] = baseline["findings"]
    assert fingerprint == finding["fingerprint"]

    {status, json, output} = lint()
    assert status == 0, output
    assert [%{"baseline" => "baselined", "blocking" => false}] = json["findings"]
    assert json["baseline"]["baselined"] == 1

    # Fixing the spec makes the entry stale: a warning, still exit 0.
    write("lib/bad.ex", """
    defmodule Consumer.Bad do
      @spec size(atom()) :: atom()
      def size(name) when is_atom(name), do: name
    end
    """)

    {status, json, output} = lint()
    assert status == 0, output
    assert json["findings"] == []
    assert [%{"fingerprint" => ^fingerprint}] = json["baseline"]["stale_findings"]

    # A module compiled without debug info cannot be analysed: SL008, exit 1.
    write("lib/no_debug.ex", """
    defmodule Consumer.NoDebug do
      @compile {:debug_info, false}
      @spec id(atom()) :: atom()
      def id(a), do: a
    end
    """)

    {status, json, output} = lint()
    assert status == 1, output

    assert [
             %{
               "rule" => "SL008",
               "subject" => "Consumer.NoDebug",
               "evidence" => "unavailable",
               "blocking" => true,
               "data" => %{"reason" => "missing_metadata", "status" => "unavailable"}
             }
           ] = json["findings"]

    assert json["ledger"]["modules"]["unavailable"] == %{"missing_metadata" => 1}

    # Acknowledging it in the inventory accepts the run.
    {_output, 0} = mix(["spec_lint.baseline"])
    {status, json, output} = lint()
    assert status == 0, output
    assert [%{"rule" => "SL008", "baseline" => "baselined"}] = json["findings"]

    # Partial runs never declare entries stale.
    {status, json, _output} = lint(["--module", "Consumer"])
    assert status == 0
    assert json["completion"]["status"] == "partial"
    assert json["baseline"]["stale_inventory"] == []
  end

  test "configuration errors exit 2 before anything runs" do
    {output, status} = mix(["spec_lint", "--profile", "strict"])
    assert status == 2
    assert output =~ "--profile must be soundness or review"

    {output, status} = mix(["spec_lint", "--module", "Nope"])
    assert status == 2
    assert output =~ "--module Nope matches nothing"

    {output, status} = mix(["spec_lint", "--rules", "SL007"])
    assert status == 2
    assert output =~ "body analysis backend"
  end

  test "--format json without --output: stdout is only the JSON report" do
    # A real source change, so compilation prints progress.
    write("lib/json_stdout.ex", """
    defmodule Consumer.JsonStdout do
      @spec id(atom()) :: atom()
      def id(a), do: a
    end
    """)

    # Standard error goes to a file, so the test output stays clean and the
    # compiler progress can be checked there.
    command = "#{System.find_executable("mix")} spec_lint --format json 2> err.txt"

    {output, 0} =
      System.cmd("sh", ["-c", command], cd: dir(), env: [{"MIX_ENV", "dev"}])

    assert {:ok, %{"schema" => "spec_lint/report"}} = JSON.decode(output)
    err = File.read!(Path.join(dir(), "err.txt"))
    assert err =~ "Compiling 1 file (.ex)"
    assert err =~ "spec_lint: "
    File.rm!(Path.join(dir(), "lib/json_stdout.ex"))
  end

  test "mix spec_lint.baseline rejects rule selection and a malformed output file" do
    for option <- [["--rules", "SL001"], ["--except", "SL001"]] do
      {output, status} = mix(["spec_lint.baseline" | option])
      assert status == 2
      assert output =~ "--rules and --except would drop the entries"
    end

    other = Path.join(dir(), "other.json")

    malformed =
      ~s({"version":1,"findings":[{"fingerprint":"sha256:x","reason":"owner said ok",) <>
        ~s("expires":"2027-01-01"}],"inventory":"oops"})

    File.write!(other, malformed)
    {output, status} = mix(["spec_lint.baseline", "--output", other])
    assert status == 2
    assert output =~ "invalid baseline"
    assert File.read!(other) == malformed
  end

  test "--analysis bodies and a throwing configuration exit 2" do
    {output, status} = mix(["spec_lint", "--analysis", "bodies"])
    assert status == 2
    assert output =~ "body analysis (analysis: :bodies) is not available"

    File.write!(Path.join(dir(), "throw.exs"), "throw(:x)")
    {output, status} = mix(["spec_lint", "--config", "throw.exs"])
    assert status == 2
    assert output =~ "cannot evaluate"
  end

  test "--explain and the console report" do
    {output, 0} = mix(["spec_lint", "--explain", "Consumer.greet/1"])
    assert output =~ "Consumer.greet/1  (lib/consumer.ex:3)"
    assert output =~ "Inferred clauses (stored in the checker chunk):"

    {output, status} = mix(["spec_lint"])
    assert status == 0
    assert output =~ "SpecLint 0.1.0"
    assert output =~ "Result: complete, exit 0"
  end
end
