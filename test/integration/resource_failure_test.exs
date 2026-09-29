defmodule SpecLint.Integration.ResourceFailureTest do
  # Resource failures (NEXT_STEPS.md, Milestone 5): a failed run must leave
  # no successful result. Each case runs `mix spec_lint` in a separate OS
  # process on a throw-away consumer project:
  #
  #   * an analysis crash inside the per-module comparison exits 2, and
  #     the report it writes says
  #     `incomplete`, never `complete`;
  #   * an exception after the per-module analysis (injected through the
  #     configuration file, which is Elixir code evaluated in the run's VM)
  #     exits 2 with no report at all, and removes an earlier report at the
  #     output path;
  #   * an exit after the analysis, or the crash of a linked process there,
  #     is the same internal failure (exit 2, no report), not Mix's status 1;
  #   * a crash of the compiler re-check process of a required reachability
  #     check makes the run incomplete (exit 2 in CI), never a verdict;
  #   * a VM killed from outside while it analyses leaves no report at the
  #     output path: the atomic write did not happen, and the earlier
  #     report was removed when the run started.
  #
  # A VM killed by the out-of-memory killer, or by any signal, cannot
  # promise exit status 2: the third case exits with the signal's status.
  # CI must treat a missing report, or one that is not `complete`, as a
  # failure (README, "Exit status"). compare_replay.sh does the same for
  # the corpus reports (SpecLint.CorpusReportTest).
  use ExUnit.Case, async: false

  alias SpecLint.ProjectFixture, as: Fixture

  @moduletag :integration
  @moduletag timeout: 300_000

  setup do
    dir = Fixture.tmp_dir!("resource")
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

    Fixture.write!(dir, "lib/consumer.ex", """
    defmodule Consumer do
      @spec greet(atom()) :: String.t()
      def greet(name) when is_atom(name), do: "hello " <> Atom.to_string(name)
    end
    """)

    {output, status} = Fixture.mix(dir, ["compile"])
    assert status == 0, output
    %{dir: dir, report: Path.join(dir, "report.json")}
  end

  test "an analysis crash inside the run exits 2 and its report is not complete",
       %{dir: dir, report: report} do
    # Inject at the comparison boundary reached by Analysis.module/2.
    # This exercises Run's per-module rescue with an actual exception while
    # keeping all BEAM artifacts produced by the supported compiler pipeline.
    Fixture.write!(dir, ".spec_lint.exs", """
    Code.compile_string(\"\"\"
    defmodule SpecLint.Compare do
      def function(_slices, _clauses, _arity), do: raise("injected comparison failure")
    end
    \"\"\")

    []
    """)

    for mode <- [["--ci"], []] do
      {output, status} =
        Fixture.mix(dir, ["spec_lint", "--format", "json", "--output", report] ++ mode)

      assert status == 2, output
      json = report |> File.read!() |> JSON.decode!()
      assert json["completion"]["status"] == "incomplete"
      assert json["completion"]["exit_code"] == 2

      assert Enum.any?(
               json["completion"]["reasons"],
               &(&1 =~ "internal failure analysing Elixir.Consumer.beam" and
                   &1 =~ "injected comparison failure")
             )
    end
  end

  test "an exception after the analysis exits 2 and leaves no report",
       %{dir: dir, report: report} do
    # A complete report from an earlier run.
    {output, 0} = Fixture.mix(dir, ["spec_lint", "--ci", "--format", "json", "--output", report])
    assert JSON.decode!(File.read!(report))["completion"]["status"] == "complete", output

    Fixture.write!(dir, ".spec_lint.exs", """
    Code.compile_string(\"\"\"
    defmodule SpecLint.Policy do
      def apply_gates(_issues, _config, _regressions), do: raise("injected failure")
    end
    \"\"\")

    []
    """)

    for mode <- [["--ci"], []] do
      File.write!(report, "{}")

      {output, status} =
        Fixture.mix(dir, ["spec_lint", "--format", "json", "--output", report] ++ mode)

      assert status == 2, output
      assert output =~ "internal failure: injected failure"
      refute File.exists?(report)
    end

    assert Path.wildcard(report <> ".tmp-*") == []
  end

  test "an exit after the analysis, or a crash of a linked process, exits 2 and leaves no report",
       %{dir: dir, report: report} do
    # Milestone 5 review: an exit, or the exit signal of a crashed linked
    # process, is not an exception; both used to end the run with status 1,
    # the status of new gated findings, in both modes.
    injections = [
      {"exit(:injected_exit)", "internal failure: exit :injected_exit"},
      {"Task.await(Task.async(fn -> raise ArgumentError end))", "internal failure: exit"}
    ]

    for {injection, message} <- injections do
      Fixture.write!(dir, ".spec_lint.exs", """
      Code.compile_string(\"\"\"
      defmodule SpecLint.Policy do
        def apply_gates(_issues, _config, _regressions), do: #{injection}
      end
      \"\"\")

      []
      """)

      for mode <- [["--ci"], []] do
        File.write!(report, "{}")

        {output, status} =
          Fixture.mix(dir, ["spec_lint", "--format", "json", "--output", report] ++ mode)

        assert status == 2, output
        assert output =~ message
        refute File.exists?(report)
      end
    end
  end

  test "a crashed reachability check makes the run incomplete, never a verdict",
       %{dir: dir, report: report} do
    # A clause conflict, so that the compiler re-check runs, in its own
    # process, for a gate that needs it.
    Fixture.write!(dir, "lib/consumer/conflict.ex", """
    defmodule Consumer.Conflict do
      @spec size(atom() | integer()) :: integer()
      def size(name) when is_atom(name), do: name
      def size(n) when is_integer(n), do: n
    end
    """)

    {output, 1} = Fixture.mix(dir, ["spec_lint", "--ci", "--format", "json", "--output", report])
    json = JSON.decode!(File.read!(report))
    assert json["completion"]["status"] == "complete", output
    assert [%{"subject" => "Consumer.Conflict.size/1", "gate" => true}] = json["findings"]

    Fixture.write!(dir, ".spec_lint.exs", """
    Code.compile_string(\"\"\"
    defmodule SpecLint.GuardFeasibility do
      def proven?(_definitions), do: raise(ArgumentError, "injected check crash")
    end
    \"\"\")

    []
    """)

    for {mode, expected} <- [{["--ci"], 2}, {[], 0}] do
      {output, status} =
        Fixture.mix(dir, ["spec_lint", "--format", "json", "--output", report] ++ mode)

      assert status == expected, output
      json = JSON.decode!(File.read!(report))
      assert json["completion"]["status"] == "incomplete"
      assert json["completion"]["exit_code"] == expected

      assert Enum.any?(
               json["completion"]["reasons"],
               &(&1 =~ "required reachability check failed for Consumer.Conflict.size/1" and
                   &1 =~ "injected check crash")
             )
    end
  end

  test "a VM killed from outside during the analysis leaves no report",
       %{dir: dir, report: report} do
    {output, 0} = Fixture.mix(dir, ["spec_lint", "--ci", "--format", "json", "--output", report])
    assert JSON.decode!(File.read!(report))["completion"]["status"] == "complete", output

    # The run stops after the per-module analysis and says where it is: the
    # OS process id of its VM, written to a marker file.
    marker = Path.join(dir, "analysing.pid")

    Fixture.write!(dir, ".spec_lint.exs", """
    Code.compile_string(\"\"\"
    defmodule SpecLint.Policy do
      def apply_gates(_issues, _config, _regressions) do
        File.write!(#{inspect(marker)}, System.pid())
        Process.sleep(:infinity)
      end
    end
    \"\"\")

    []
    """)

    port =
      Port.open({:spawn_executable, System.find_executable("mix")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["spec_lint", "--ci", "--format", "json", "--output", report],
        cd: dir,
        env: for({key, value} <- Fixture.env(), do: {~c"#{key}", port_value(value)})
      ])

    pid = await_marker(marker, port, 240_000)
    {_, 0} = System.cmd("kill", ["-KILL", pid])
    status = await_exit(port, "")

    assert status != 0
    assert status != 2
    refute File.exists?(report)
    assert Path.wildcard(report <> ".tmp-*") == []
  end

  # Port environment values are charlists; `false` unsets a variable.
  defp port_value(nil), do: false
  defp port_value(value), do: String.to_charlist(value)

  defp await_marker(marker, port, timeout) when timeout > 0 do
    case File.read(marker) do
      {:ok, pid} when pid != "" ->
        pid

      _ ->
        receive do
          {^port, {:exit_status, status}} -> flunk("the run exited #{status} before the marker")
        after
          100 -> await_marker(marker, port, timeout - 100)
        end
    end
  end

  defp await_marker(_marker, _port, _timeout), do: flunk("the run never reached the marker")

  defp await_exit(port, output) do
    receive do
      {^port, {:data, data}} -> await_exit(port, output <> data)
      {^port, {:exit_status, status}} -> status
    after
      60_000 -> flunk("the killed run did not exit: " <> output)
    end
  end
end
