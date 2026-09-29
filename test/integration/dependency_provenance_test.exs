defmodule SpecLint.Integration.DependencyProvenanceTest do
  use ExUnit.Case, async: false

  alias SpecLint.{Beam, Config, Project, Run}
  alias SpecLint.ProjectFixture, as: Fixture

  @moduletag :integration
  @moduletag timeout: 600_000

  @dependency """
  defmodule StoredDependency do
    @spec value(boolean(), atom()) :: atom()
    def value(flag, value) do
      into = if flag, do: [], else: ""
      _ = for _ <- [1], do: value, into: into
      value
    end
  end
  """

  setup do
    root = Fixture.tmp_dir!("dependency-provenance")
    on_exit(fn -> File.rm_rf!(root) end)
    dir = Path.join(root, "consumer")
    dep = Path.join(root, "dependency")

    Fixture.write!(dep, "mix.exs", """
    defmodule StoredDependency.MixProject do
      use Mix.Project
      def project, do: [app: :stored_dependency, version: "0.1.0"]
    end
    """)

    Fixture.write!(dep, "lib/stored_dependency.ex", @dependency)
    middle = Path.join(root, "middle")

    Fixture.write!(middle, "mix.exs", """
    defmodule MiddleDependency.MixProject do
      use Mix.Project
      def project, do: [app: :middle_dependency, version: "0.1.0",
        deps: [{:stored_dependency, path: "../dependency"}]]
    end
    """)

    Fixture.write!(middle, "lib/middle_dependency.ex", """
    defmodule MiddleDependency do
      @spec value(boolean(), atom()) :: atom()
      def value(flag, value), do: StoredDependency.value(flag, value)
    end
    """)

    Fixture.write!(dir, "mix.exs", """
    defmodule StoredConsumer.MixProject do
      use Mix.Project
      def project do
        [app: :stored_consumer, version: "0.1.0", deps: [
          {:middle_dependency, path: "../middle"},
          {:spec_lint, path: #{inspect(Fixture.root())}, only: [:dev, :test], runtime: false}
        ]]
      end
    end
    """)

    Fixture.write!(dir, "lib/stored_consumer.ex", """
    defmodule StoredConsumer do
      @spec value(boolean(), atom()) :: atom()
      def value(flag, value), do: MiddleDependency.value(flag, value)
    end
    """)

    build = Path.join(dir, "_build/dev/lib")

    %{
      dir: dir,
      dep: dep,
      dep_beam: Path.join(build, "stored_dependency/ebin/Elixir.StoredDependency.beam"),
      dep_record: Path.join(build, "stored_dependency/.mix/spec_lint.build"),
      record: Path.join(build, "stored_consumer/.mix/spec_lint.build")
    }
  end

  @tag :diagnostic_dependency
  @tag adapter: SpecLint.Compiler.V121
  test "actual 648 dependency signatures cannot certify a false c24 consumer gate", context do
    assert String.starts_with?(System.build_info()[:revision], "c24c235"),
           "run this exact compiler-defect regression under c24c235"

    other_bin = System.fetch_env!("SPEC_LINT_DIAGNOSTIC_ELIXIR")

    {identity, 0} =
      System.cmd(Path.join(other_bin, "elixir"), [
        "-e",
        "IO.write(System.build_info()[:revision])"
      ])

    assert String.starts_with?(identity, "648b2a9")

    {_output, 0} =
      System.cmd(Path.join(other_bin, "mix"), ["compile"],
        cd: context.dir,
        env: Fixture.env([{"PATH", other_bin <> ":" <> System.get_env("PATH")}]),
        stderr_to_stdout: true
      )

    assert {:ok, "elixir_checker_v10"} = Beam.checker_version(context.dep_beam)
    foreign = File.read!(context.dep_beam)

    {status, json, output} = Fixture.lint(context.dir)
    assert status == 0, output
    assert json["completion"]["status"] == "complete"
    assert json["findings"] == []
    assert output =~ "recompiling stored_dependency"
    refute File.read!(context.dep_beam) == foreign
    assert read(context.dep_record)["adapter"] == "1.21.0-dev+c24c235"
    assert Map.has_key?(read(context.record)["dependencies"], "stored_dependency")

    {output, 0} =
      Fixture.mix(context.dir, [
        "run",
        "--no-start",
        "-e",
        "IO.inspect(StoredConsumer.value(true, :ok), label: :witness)"
      ])

    assert output =~ "witness: :ok"
  end

  test "a dependency ExCk-only change invalidates a recorded consumer before Run", context do
    {_status, _json, _output} = Fixture.lint(context.dir)
    {md5, original_exck} = Beam.identity(context.dep_beam)
    swap_checker_version!(context.dep_beam)
    assert {^md5, changed_exck} = Beam.identity(context.dep_beam)
    refute changed_exck == original_exck

    ebin = Path.join(context.dir, "_build/dev/lib/stored_consumer/ebin")
    project = Project.from_ebins([{:stored_consumer, ebin}], context.dir)
    assert {:error, message} = Run.execute(project, %Config{baseline: "missing.json"}, ci: true)
    assert message =~ "dependency compiler artifacts changed after inference (stored_dependency)"

    {status, json, output} = Fixture.lint(context.dir)
    assert output =~ "recompiling stored_dependency"

    assert output =~
             ~r/==> stored_dependency.*Compiling 1 file.*==> middle_dependency.*Compiling 1 file/s

    assert output =~ "recompiling stored_consumer"

    assert json["completion"]["status"] ==
             if(diagnostic_only?(), do: "incomplete", else: "complete")

    assert status == if(diagnostic_only?(), do: 2, else: 0)
    assert {:ok, checker} = Beam.checker_version(context.dep_beam)
    assert checker == Atom.to_string(:elixir_erl.checker_version())
  end

  test "an orphan dependency BEAM is retained and never stamped", context do
    {_status, _json, _output} = Fixture.lint(context.dir)
    prior = File.read!(context.dep_record)
    orphan = Path.join(Path.dirname(context.dep_beam), "Elixir.DependencyOrphan.beam")
    source = String.replace(@dependency, "StoredDependency", "DependencyOrphan")

    {_output, 0} =
      System.cmd(System.find_executable("elixir"), [
        "-e",
        "[{_, bytes}] = Code.compile_string(#{inspect(source)}); File.write!(#{inspect(orphan)}, bytes)"
      ])

    original = File.read!(orphan)
    {status, json, output} = Fixture.lint(context.dir)
    assert status == 2, output
    assert json == nil

    assert output =~
             "cannot verify compiler provenance for stored_dependency: Elixir.DependencyOrphan.beam"

    assert File.read!(orphan) == original
    assert File.read!(context.dep_record) == prior
    refute File.exists?(context.record)
  end

  test "custom cache compilation in a dependency is refused", context do
    {_status, _json, _output} = Fixture.lint(context.dir)
    file = Path.join(context.dep, "mix.exs")

    File.write!(
      file,
      String.replace(
        File.read!(file),
        "app: :stored_dependency,",
        "app: :stored_dependency, compilers: Mix.compilers() ++ [:restore_cache],"
      ) <>
        """

        defmodule Mix.Tasks.Compile.RestoreCache do
          use Mix.Task.Compiler
          def run(_args), do: {:noop, []}
        end
        """
    )

    {status, json, output} = Fixture.lint(context.dir)
    assert status == 2, output
    assert json == nil
    assert output =~ "unsupported compiler pipeline for stored_dependency"
    refute File.exists?(context.record)
  end

  test "dependency project validation uses the actual prod environment", context do
    file = Path.join(context.dep, "mix.exs")

    File.write!(
      file,
      String.replace(
        File.read!(file),
        "app: :stored_dependency,",
        "app: :stored_dependency, compilers: if(Mix.env() == :prod, do: Mix.compilers(), else: Mix.compilers() ++ [:dev_only]),"
      )
    )

    {status, json, output} = Fixture.lint(context.dir)
    assert status == if(diagnostic_only?(), do: 2, else: 0), output
    assert json != nil
    assert File.exists?(context.dep_record)
  end

  defp read(path), do: path |> File.read!() |> JSON.decode!()
  defp diagnostic_only?, do: String.starts_with?(System.build_info()[:revision], "648b2a9")

  defp swap_checker_version!(beam) do
    {:ok, _module, chunks} = :beam_lib.all_chunks(String.to_charlist(beam))
    {_version, data} = :erlang.binary_to_term(:proplists.get_value(~c"ExCk", chunks))

    chunks =
      List.keyreplace(
        chunks,
        ~c"ExCk",
        0,
        {~c"ExCk", :erlang.term_to_binary({:elixir_checker_v0, data})}
      )

    {:ok, bytes} = :beam_lib.build_module(chunks)
    File.write!(beam, bytes)
  end
end
