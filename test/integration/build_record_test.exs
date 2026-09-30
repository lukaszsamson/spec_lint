defmodule SpecLint.Integration.BuildRecordTest do
  # Artifacts of another compiler build, through the public Mix tasks
  # (Milestone 2 review). Both qualified builds are 1.21.0-dev with checker
  # chunk v10, so Mix never recompiles when the compiler changes; before the
  # build record, `mix spec_lint --ci` analysed the other build's BEAM files
  # and reported that build's verdict under the running adapter's id (exit
  # 0 where the running build gates, and the reverse).
  #
  # The cross-compiler test (tag :cross_compiler) needs SPEC_LINT_OTHER_ELIXIR,
  # the bin directory of another qualified compiler: the other 1.21 build
  # (Milestone 2), or the other compiler line, 1.20.4 under 1.21 and the
  # reverse (Milestone 3). test_helper.exs excludes it when the variable is
  # unset, so the summary counts it as excluded instead of passed; with
  # `--only cross_compiler` and no variable it fails.
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 600_000

  alias SpecLint.{Config, Project, Run}
  alias SpecLint.ProjectFixture, as: Fixture

  # Audit row 19: correct under c24c235, a false SL003 under 648b2a9,
  # whose checker is therefore restricted to diagnostic-only analysis.
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

  # Writes lib/generated.ex once, like a source generator.
  @generate """
  defmodule Mix.Tasks.Compile.Generate do
    use Mix.Task.Compiler
    def run(_args) do
      if File.exists?("lib/generated.ex") do
        {:noop, []}
      else
        File.write!("lib/generated.ex", "defmodule Generated do\n  def value, do: :ok\nend\n")
        {:ok, []}
      end
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

  test "Elixir and Erlang compiler outputs both receive artifact evidence", %{
    dir: dir,
    record: record
  } do
    Fixture.write!(dir, "src/erlang_probe.erl", """
    -module(erlang_probe).
    -export([tag/1]).
    tag(_) -> ok.
    """)

    {status, json, output} = Fixture.lint(dir)
    assert_native_verdict(status, json, output)
    assert Map.has_key?(read(record)["beams"], "erlang_probe.beam")
    assert Map.has_key?(read(record)["beams"], "Elixir.IntoProbe.beam")

    {status, json, output} = Fixture.lint(dir)
    refute output =~ "recompiling"
    assert_native_verdict(status, json, output)
  end

  test "a later cache compiler cannot attest overwritten Elixir output", %{
    dir: dir,
    record: record
  } do
    {_output, 0} = Fixture.mix(dir, ["compile"])
    beam = Path.join(dir, "_build/dev/lib/consumer/ebin/Elixir.IntoProbe.beam")
    File.cp!(beam, Path.join(dir, "cached.beam"))
    swap_checker_version!(Path.join(dir, "cached.beam"), :elixir_checker_v0)

    mix_file = Path.join(dir, "mix.exs")
    project = File.read!(mix_file)

    project =
      String.replace(
        project,
        "app: :consumer,",
        "app: :consumer, compilers: Mix.compilers() ++ [:cache],"
      )

    File.write!(
      mix_file,
      project <>
        """

        defmodule Mix.Tasks.Compile.Cache do
          use Mix.Task.Compiler
          def run(_args) do
            File.cp!("cached.beam", Path.join(Mix.Project.compile_path(), "Elixir.IntoProbe.beam"))
            {:ok, []}
          end
        end
        """
    )

    # A cache artifact has the same module name as the output just compiled,
    # but a distinct checker/signature payload. No event describes this copy.
    {status, json, output} = Fixture.lint(dir)
    assert status == 2, output
    assert json == nil
    assert output =~ "unsupported compiler pipeline for consumer"
    assert output =~ "stage :cache runs after :erlang"
    refute File.exists?(record)

    {output, status} = Fixture.mix(dir, ["spec_lint.baseline"])
    assert status == 2, output
    assert output =~ "unsupported compiler pipeline"
    refute File.exists?(record)
    refute File.exists?(Path.join(dir, ".spec_lint_baseline.json"))
  end

  test "a recorded build cannot skip Elixir compilation after a source edit", %{
    dir: dir,
    record: record
  } do
    {_status, _json, _output} = Fixture.lint(dir)
    previous = File.read!(record)

    Fixture.write!(dir, "lib/into_probe.ex", """
    defmodule IntoProbe do
      @spec f(boolean(), atom()) :: atom()
      def f(_flag, _value), do: 123
    end
    """)

    mix_file = Path.join(dir, "mix.exs")
    original = File.read!(mix_file)

    for compilers <- [
          [],
          [:erlang, :app],
          [:leex, :yecc, :erlang, :erlang, :elixir, :app],
          [:leex, :yecc, :elixir, :erlang, :app],
          [:leex, :yecc, :erlang, :app, :elixir]
        ] do
      File.write!(
        mix_file,
        String.replace(
          original,
          "app: :consumer,",
          "app: :consumer, compilers: #{inspect(compilers)},"
        )
      )

      {status, json, output} = Fixture.lint(dir)
      assert status == 2, output
      assert json == nil
      assert output =~ "unsupported compiler pipeline for consumer"
      assert File.read!(record) == previous
    end
  end

  test "duplicated generators and custom prefix stages are verified", %{dir: dir, record: record} do
    # :watcher is implemented by an alias, as file_system does.
    with_compilers!(
      dir,
      "[:leex, :generate, :yecc, :watcher, :leex] ++ Mix.compilers(), " <>
        "aliases: [\"compile.watcher\": fn _ -> :ok end]",
      @generate
    )

    Fixture.write!(dir, "src/probe_parser.yrl", """
    Nonterminals value.
    Terminals integer.
    Rootsymbol value.
    value -> integer : '$1'.
    """)

    {status, json, output} = Fixture.lint(dir)
    assert_native_verdict(status, json, output)
    beams = read(record)["beams"]

    for file <- ~w(Elixir.IntoProbe.beam Elixir.Generated.beam probe_parser.beam) do
      assert Map.has_key?(beams, file), inspect(Map.keys(beams))
    end

    assert read(record)["compilers"] == ~w(leex generate yecc watcher leex erlang elixir app)

    assert_recorded_as_built(dir, record)

    previous = File.read!(record)
    {status, json, output} = Fixture.lint(dir)
    refute output =~ "recompiling"
    assert_native_verdict(status, json, output)
    assert File.read!(record) == previous
  end

  test "a prefix stage rewriting a verified BEAM of an unchanged module is refused",
       %{dir: dir, record: record} do
    with_compilers!(dir, "[:restore] ++ Mix.compilers()", """
    defmodule Mix.Tasks.Compile.Restore do
      use Mix.Task.Compiler
      def run(_args) do
        if File.exists?("cached.beam") do
          File.rename!("cached.beam", Path.join(Mix.Project.compile_path(), "Elixir.IntoProbe.beam"))
          {:ok, []}
        else
          {:noop, []}
        end
      end
    end
    """)

    {status, json, output} = Fixture.lint(dir)
    assert_native_verdict(status, json, output)
    previous = File.read!(record)
    beam = Path.join(dir, "_build/dev/lib/consumer/ebin/Elixir.IntoProbe.beam")
    cached = Path.join(dir, "cached.beam")
    File.cp!(beam, cached)
    swap_checker_version!(cached, :elixir_checker_v0)
    restored = File.read!(cached)

    # The record is current, so nothing is forced; the prefix stage replaces
    # the BEAM of a module Mix does not recompile, and no event names it.
    {status, json, output} = Fixture.lint(dir)
    assert status == 2, output
    assert json == nil
    assert output =~ "cannot verify compiler provenance for consumer: Elixir.IntoProbe.beam"
    assert File.read!(beam) == restored
    assert File.read!(record) == previous

    # The changed artifact makes the next run recompile: the Elixir stage
    # runs after the prefix stage and its event attests the new output.
    {status, json, output} = Fixture.lint(dir)
    assert output =~ "recompiling consumer with #{adapter_id()}: BEAM files changed", output
    assert_native_verdict(status, json, output)
    refute File.read!(beam) == restored
    assert {:ok, checker} = SpecLint.Beam.checker_version(beam)
    assert checker == running_checker()
    assert_recorded_as_built(dir, record)
  end

  test "a changed list of prefix stages forces recompilation", %{dir: dir, record: record} do
    with_compilers!(dir, "[:generate] ++ Mix.compilers()", @generate)
    {status, json, output} = Fixture.lint(dir)
    assert_native_verdict(status, json, output)

    with_compilers!(
      dir,
      "[:generate, :other] ++ Mix.compilers()",
      @generate <>
        """
        defmodule Mix.Tasks.Compile.Other do
          use Mix.Task.Compiler
          def run(_args), do: {:noop, []}
        end
        """
    )

    {status, json, output} = Fixture.lint(dir)

    assert output =~ "recompiling consumer with #{adapter_id()}: compiler pipeline changed",
           output

    assert_recompiled(output)
    assert_native_verdict(status, json, output)
    assert read(record)["compilers"] == ~w(yecc leex generate other erlang elixir app)
    assert_recorded_as_built(dir, record)

    {_status, _json, output} = Fixture.lint(dir)
    refute output =~ "recompiling"
  end

  test "compile aliases cannot restore a cache after emitted modules", %{dir: dir, record: record} do
    {_status, _json, _output} = Fixture.lint(dir)
    previous = File.read!(record)
    beam = Path.join(dir, "_build/dev/lib/consumer/ebin/Elixir.IntoProbe.beam")
    File.cp!(beam, Path.join(dir, "cached.beam"))
    swap_checker_version!(Path.join(dir, "cached.beam"), :elixir_checker_v0)

    mix_file = Path.join(dir, "mix.exs")
    original = File.read!(mix_file)

    for task <- [:compile, :"compile.elixir"] do
      project =
        String.replace(
          original,
          "app: :consumer,",
          "app: :consumer, aliases: [{#{inspect(task)}, [#{inspect(Atom.to_string(task))}, \"restore_cache\"]}],"
        )

      File.write!(
        mix_file,
        project <>
          """

          defmodule Mix.Tasks.RestoreCache do
            use Mix.Task
            def run(_args) do
              File.cp!("cached.beam", Path.join(Mix.Project.compile_path(), "Elixir.IntoProbe.beam"))
            end
          end
          """
      )

      {status, json, output} = Fixture.lint(dir)
      assert status == 2, output
      assert json == nil
      assert output =~ "unsupported compiler pipeline for consumer: alias #{task}"
      assert File.read!(record) == previous
      refute File.read!(beam) == File.read!(Path.join(dir, "cached.beam"))
    end
  end

  # Review: the aliases accepted for custom prefix stages must not admit
  # an alias of compile that can replace its output, or an alias of a
  # built-in stage next to an accepted custom stage. The one exception is a
  # flag-only self-alias (a Hex package with
  # `compile: ["compile --warnings-as-errors"]` blocked adoption): Mix runs
  # the built-in task with those flags.
  test "replacing aliases of compile and of built-in stages stay refused beside custom stages",
       %{dir: dir, record: record} do
    {_status, _json, _output} = Fixture.lint(dir)
    previous = File.read!(record)

    for {aliases, task} <- [
          {~s(compile: ["compile.elixir"]), "compile"},
          {~s(compile: ["compile", "format"]), "compile"},
          {~s(compile: ["compile lib"]), "compile"},
          {~s(compile: [fn _ -> :ok end]), "compile"},
          {~s(compile: []), "compile"},
          {~s(compile: ["compile --no-compile"]), "compile"},
          {~s(compile: ["compile --no-debug-info"]), "compile"},
          {~s(compile: ["compile --no-deps-check"]), "compile"},
          {~s(compile: ["compile --unknown"]), "compile"},
          {~s(compile: ["compile --warnings-as-errors --no-warnings-as-errors"]), "compile"},
          {~s(compile: ["compile --warnings-as-errors=false"]), "compile"},
          {~s(compile: ["compile --warnings-as-errors --warnings-as-errors"]), "compile"},
          {~s(compile: ["compile --no-all-warnings", "compile --no-all-warnings"]), "compile"},
          {~s(compile: ["compile '--no-all-warnings"]), "compile"},
          {~s("compile.watcher": fn _ -> :ok end, "compile.erlang": ["compile.erlang", "format"]),
           "compile.erlang"},
          {~s("compile.watcher": fn _ -> :ok end, "compile.yecc": fn _ -> :ok end),
           "compile.yecc"}
        ] do
      with_compilers!(dir, "[:watcher] ++ Mix.compilers(), aliases: [#{aliases}]", "")
      {status, json, output} = Fixture.lint(dir)
      assert status == 2, output
      assert json == nil
      assert output =~ "unsupported compiler pipeline for consumer: alias #{task} ", output
      assert File.read!(record) == previous
    end
  end

  test "a flag-only self-alias of compile is accepted and still forced", %{
    dir: dir,
    record: record
  } do
    with_compilers!(
      dir,
      ~s|Mix.compilers(), aliases: [compile: ["compile '--no-all-warnings'"]]|,
      ""
    )

    {status, json, output} = Fixture.lint(dir)
    assert_native_verdict(status, json, output)
    assert read(record)["compilers"] == ~w(yecc leex erlang elixir app)

    # The forced recompile after another build's record goes through the alias.
    other_build!(record)
    {status, json, output} = Fixture.lint(dir)
    assert_recompiled(output)
    assert_native_verdict(status, json, output)
    assert_recorded_as_built(dir, record)
  end

  # Mix.Task.run/2 does nothing when `compile` already ran in the VM, so a
  # forced recompile after `mix do compile + spec_lint` (or an alias, or a
  # task defined in the project, which Mix compiles to find it) used to be a
  # no-op, and the other build's BEAM files were then recorded as the running
  # build's (Milestone 3 review, high).
  test "the forced recompile runs even when compile already ran in the VM",
       %{dir: dir, record: record} do
    {_status, _json, _output} = Fixture.lint(dir)
    other_build!(record)

    {output, status} =
      Fixture.mix(dir, ["do", "compile", "+", "spec_lint", "--ci"] ++ json_output(dir))

    assert_recompiled(output)
    assert_native_verdict(status, report(dir), output)
    assert_recorded_as_built(dir, record)

    # The same through a task defined in the project (the self-check's shape:
    # Mix compiles the project to find the task before the task runs).
    Fixture.write!(dir, "lib/mix/tasks/lint_here.ex", """
    defmodule Mix.Tasks.LintHere do
      use Mix.Task
      def run(args), do: Mix.Tasks.SpecLint.run(args)
    end
    """)

    {_output, 0} = Fixture.mix(dir, ["compile"])
    {_status, _json, _output} = Fixture.lint(dir)
    other_build!(record)
    {output, status} = Fixture.mix(dir, ["lint_here", "--ci"] ++ json_output(dir))
    assert_recompiled(output)
    assert_native_verdict(status, report(dir), output)
    assert_recorded_as_built(dir, record)
  end

  # A dependency BEAM of another compiler line (another checker chunk
  # version) is ignored by the running checker, so calls into it become
  # dynamic() and a gate disappears (Milestone 3 review). Mix keeps such a
  # BEAM with --no-deps-check, a shared or stale build directory or vendored
  # files; the test swaps the chunk version in place.
  test "a source-backed dependency from another compiler line is rebuilt before its caller" do
    dir = Fixture.tmp_dir!("foreign-dep")
    on_exit(fn -> File.rm_rf!(dir) end)
    dep = Path.join(dir, "dep_a")
    consumer = Path.join(dir, "consumer")

    Fixture.write!(dep, "mix.exs", """
    defmodule DepA.MixProject do
      use Mix.Project
      def project, do: [app: :dep_a, version: "0.1.0"]
    end
    """)

    Fixture.write!(dep, "lib/dep_a.ex", """
    defmodule DepA do
      def tag(x) when is_integer(x), do: :ok
    end
    """)

    Fixture.write!(consumer, "mix.exs", """
    defmodule Consumer.MixProject do
      use Mix.Project

      def project do
        [
          app: :consumer,
          version: "0.1.0",
          deps: [
            {:dep_a, path: "../dep_a"},
            {:spec_lint, path: #{inspect(Fixture.root())}, only: [:dev, :test], runtime: false}
          ]
        ]
      end
    end
    """)

    Fixture.write!(consumer, "lib/consumer.ex", """
    defmodule Consumer do
      @spec f(integer()) :: binary()
      def f(x), do: DepA.tag(x)
    end
    """)

    {status, json, output} = Fixture.lint(consumer)
    assert status == 1, output
    assert [%{"rule" => "SL001"}] = json["findings"]

    beam = Path.join(consumer, "_build/dev/lib/dep_a/ebin/Elixir.DepA.beam")
    {md5, _exck} = SpecLint.Beam.identity(beam)
    swap_checker_version!(beam, :elixir_checker_v0)
    assert {^md5, _exck} = SpecLint.Beam.identity(beam)

    # Changing only ExCk does not change the code MD5. The dependency
    # record's full byte digest still triggers its own and caller's rebuild.
    {status, json, output} = Fixture.lint(consumer)
    assert output =~ "recompiling dep_a", output
    assert output =~ "recompiling consumer", output
    assert status == 1, output
    assert [%{"rule" => "SL001"}] = json["findings"]
    assert {:ok, checker} = SpecLint.Beam.checker_version(beam)
    assert checker == Atom.to_string(:elixir_erl.checker_version())
  end

  @tag :cross_compiler
  test "a copied orphan from another actual compiler is never stamped as this build",
       %{dir: dir, record: record} do
    other_bin = System.get_env("SPEC_LINT_OTHER_ELIXIR") || flunk("set SPEC_LINT_OTHER_ELIXIR")
    {_status, _json, _output} = Fixture.lint(dir)
    previous = File.read!(record)
    beam = Path.join(dir, "_build/dev/lib/consumer/ebin/Elixir.OrphanIntoProbe.beam")
    source = String.replace(@source, "IntoProbe", "OrphanIntoProbe")

    {output, 0} =
      System.cmd(Path.join(other_bin, "elixir"), [
        "-e",
        "[{_, binary}] = Code.compile_string(#{inspect(source)}); " <>
          "File.write!(#{inspect(beam)}, binary)"
      ])

    original = File.read!(beam)
    {other_id, other_checker} = other_identity(other_bin)
    refute other_id == adapter_id(), output
    assert {:ok, ^other_checker} = SpecLint.Beam.checker_version(beam)

    # Same-line qualified builds have identical chunk versions; the actual
    # other compiler, rather than a synthetic chunk edit, supplies this BEAM.
    {status, json, output} = Fixture.lint(dir)
    assert status == 2, output
    assert json == nil
    assert output =~ "cannot verify compiler provenance for consumer: Elixir.OrphanIntoProbe.beam"
    assert File.read!(beam) == original
    assert File.read!(record) == previous
    refute Map.has_key?(read(record)["beams"], "Elixir.OrphanIntoProbe.beam")

    File.rm!(record)
    {output, status} = Fixture.mix(dir, ["spec_lint.baseline"])
    assert status == 2, output
    assert output =~ "cannot verify compiler provenance"
    refute File.exists?(record)
    refute File.exists?(Path.join(dir, ".spec_lint_baseline.json"))
    assert File.read!(beam) == original

    File.rm!(beam)
    {status, json, output} = Fixture.lint(dir)
    assert_native_verdict(status, json, output)
  end

  @tag :cross_compiler
  test "a build compiled by the other qualified compiler is rebuilt before it is analysed",
       %{dir: dir, record: record} do
    case System.get_env("SPEC_LINT_OTHER_ELIXIR") do
      nil ->
        flunk("set SPEC_LINT_OTHER_ELIXIR to the bin directory of another qualified compiler")

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

        if String.ends_with?(other_id, "+648b2a9") do
          assert other_status == 2
          assert other_json["completion"]["status"] == "incomplete"
          assert Enum.all?(other_json["findings"], &(not &1["gate"]))
        else
          assert other_status == if(other_json["findings"] == [], do: 0, else: 1)
        end

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

        # (e) compiled by the other compiler, then `mix do compile +
        # spec_lint` by this one: compile already ran in the VM when the
        # forced recompile starts (Milestone 3 review).
        {_output, 0} = other.(["compile", "--force"])

        {output, status} =
          Fixture.mix(dir, ["do", "compile", "+", "spec_lint", "--ci"] ++ json_output(dir))

        assert_recompiled(output)
        assert_native_verdict(status, report(dir), output)
        assert_recorded_as_built(dir, record)
    end
  end

  # Sets the compilers of the fixture's mix.exs and appends `tasks`.
  defp with_compilers!(dir, compilers, tasks) do
    file = Path.join(dir, "mix.exs")
    original = Process.get({:original_mix, dir}) || File.read!(file)
    Process.put({:original_mix, dir}, original)

    File.write!(
      file,
      String.replace(original, "app: :consumer,", "app: :consumer, compilers: #{compilers},") <>
        "\n" <> tasks
    )
  end

  defp swap_checker_version!(beam, version) do
    {:ok, _module, chunks} = :beam_lib.all_chunks(String.to_charlist(beam))
    {_tag, data} = :erlang.binary_to_term(:proplists.get_value(~c"ExCk", chunks))

    chunks =
      List.keyreplace(chunks, ~c"ExCk", 0, {~c"ExCk", :erlang.term_to_binary({version, data})})

    {:ok, binary} = :beam_lib.build_module(chunks)
    File.write!(beam, binary)
  end

  # Marks the record as written by another build of the running line.
  defp other_build!(record) do
    File.write!(
      record,
      JSON.encode!(%{read(record) | "build_digest" => String.duplicate("0", 64)})
    )
  end

  defp json_output(dir), do: ["--format", "json", "--output", Path.join(dir, "report.json")]
  defp report(dir), do: dir |> Path.join("report.json") |> File.read!() |> JSON.decode!()

  # The announced recompilation compiled the project.
  defp assert_recompiled(output) do
    assert [_, after_notice] = String.split(output, "spec_lint: recompiling consumer", parts: 2),
           output

    assert after_notice =~ ~r/Compiling \d+ files? \(\.ex\)/, output
  end

  # The record names the running build and the BEAM files now in the ebin.
  defp assert_recorded_as_built(dir, record) do
    ebin = Path.join(dir, "_build/dev/lib/consumer/ebin")

    beams =
      for path <- Path.wildcard(Path.join(ebin, "*.beam")), into: %{} do
        {Path.basename(path),
         :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)}
      end

    assert %{"adapter" => adapter, "beams" => ^beams} = read(record)
    assert adapter == adapter_id()
    assert read(record)["build_digest"] == report(dir)["artifacts"]["build_digest"]
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
        assert status == 2, output
        assert [%{"rule" => "SL003", "blocking" => false}] = json["findings"]
        assert json["completion"]["status"] == "incomplete"

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
