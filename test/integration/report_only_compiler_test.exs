defmodule SpecLint.Integration.ReportOnlyCompilerTest do
  use ExUnit.Case, async: false

  alias SpecLint.ProjectFixture, as: Fixture

  @moduletag :integration
  @moduletag timeout: 120_000
  @moduletag skip: not String.starts_with?(System.build_info().revision, "648b2a9")

  test "public tasks cannot certify or baseline a clean project on the diagnostic compiler" do
    dir = Fixture.tmp_dir!("report-only-compiler")
    on_exit(fn -> File.rm_rf!(dir) end)

    Fixture.write!(dir, "mix.exs", """
    defmodule DiagnosticConsumer.MixProject do
      use Mix.Project
      def project do
        [app: :diagnostic_consumer, version: "0.1.0",
         deps: [{:spec_lint, path: #{inspect(Fixture.root())}, runtime: false}]]
      end
    end
    """)

    Fixture.write!(dir, "lib/consumer.ex", """
    defmodule DiagnosticConsumer do
      @spec identity(:ok) :: :ok
      def identity(:ok), do: :ok
    end
    """)

    for {options, expected} <- [{[], 0}, {["--ci"], 2}, {["--warnings-as-errors"], 2}] do
      {output, status} =
        Fixture.mix(dir, ["spec_lint", "--format", "json", "--output", "report.json"] ++ options)

      assert status == expected, output
      report = dir |> Path.join("report.json") |> File.read!() |> JSON.decode!()
      assert report["completion"]["status"] == "incomplete"
      assert report["completion"]["exit_code"] == expected
      assert Enum.all?(report["findings"], &(not &1["gate"]))
      assert Enum.any?(report["completion"]["reasons"], &String.contains?(&1, "diagnostic-only"))
    end

    {output, status} = Fixture.mix(dir, ["spec_lint.baseline"])
    assert status == 2, output
    refute File.exists?(Path.join(dir, ".spec_lint_baseline.json"))
  end
end
