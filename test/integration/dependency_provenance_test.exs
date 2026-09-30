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

  test "both source generator orders attest owned and dependency artifacts", context do
    for {dir, app} <- [{context.dir, :stored_consumer}, {context.dep, :stored_dependency}] do
      file = Path.join(dir, "mix.exs")

      File.write!(
        file,
        String.replace(
          File.read!(file),
          "app: #{inspect(app)},",
          "app: #{inspect(app)}, compilers: [:leex, :yecc, :erlang, :elixir, :app],"
        )
      )

      Fixture.write!(dir, "src/#{app}_scanner.xrl", """
      Definitions.
      D = [0-9]
      Rules.
      {D}+ : {token, {integer, TokenLine, list_to_integer(TokenChars)}}.
      Erlang code.
      """)
    end

    {status, json, output} = Fixture.lint(context.dir)
    assert status == if(diagnostic_only?(), do: 2, else: 0), output
    assert json != nil
    assert File.exists?(context.record)
    assert File.exists?(context.dep_record)

    for app <- [:stored_consumer, :stored_dependency] do
      assert File.exists?(
               Path.join(context.dir, "_build/dev/lib/#{app}/ebin/#{app}_scanner.beam")
             )
    end

    previous = File.read!(context.record)
    {again, _json, output} = Fixture.lint(context.dir)
    assert again == status, output
    refute output =~ "Compiling"
    assert File.read!(context.record) == previous
  end

  test "a custom prefix stage in a dependency is recorded and verified", context do
    file = Path.join(context.dep, "mix.exs")

    File.write!(
      file,
      String.replace(
        File.read!(file),
        "app: :stored_dependency,",
        "app: :stored_dependency, compilers: [:yecc, :generate_dependency] ++ Mix.compilers(),"
      ) <>
        """

        defmodule Mix.Tasks.Compile.GenerateDependency do
          use Mix.Task.Compiler
          def run(_args) do
            if File.exists?("lib/generated_dependency.ex") do
              {:noop, []}
            else
              File.write!("lib/generated_dependency.ex",
                "defmodule GeneratedDependency do\n  def value, do: :ok\nend\n")
              {:ok, []}
            end
          end
        end
        """
    )

    {status, json, output} = Fixture.lint(context.dir)
    assert status == if(diagnostic_only?(), do: 2, else: 0), output
    assert json != nil
    dep_record = read(context.dep_record)
    assert dep_record["compilers"] == ~w(leex yecc generate_dependency erlang elixir app)
    assert Map.has_key?(dep_record["beams"], "Elixir.GeneratedDependency.beam")
    assert Map.has_key?(read(context.record)["dependencies"], "stored_dependency")

    previous = File.read!(context.dep_record)
    {again, _json, output} = Fixture.lint(context.dir)
    assert again == status, output
    refute output =~ "recompiling"
    assert File.read!(context.dep_record) == previous
  end

  # Mix's deps.compile stores the dependency list of a fetchable dependency
  # in its SCM manifest after compiling it. Without that, the next Mix
  # command sees the dependency as outdated, deletes its build directory
  # (and its record) and recompiles it, so every run rebuilt everything.
  test "a fetchable dependency compiled by spec_lint stays up to date for Mix", context do
    use_git_middle!(context)
    {_output, 0} = Fixture.mix(context.dir, ["deps.get"])
    {status, json, output} = Fixture.lint(context.dir)
    assert status == if(diagnostic_only?(), do: 2, else: 0), output
    assert json != nil

    middle_record =
      Path.join(context.dir, "_build/dev/lib/middle_dependency/.mix/spec_lint.build")

    previous = File.read!(middle_record)

    {output, 0} = Fixture.mix(context.dir, ["deps"])
    refute output =~ "outdated", output

    {again, _json, output} = Fixture.lint(context.dir)
    assert again == status, output
    refute output =~ "recompiling", output
    refute output =~ "Generated middle_dependency", output
    assert File.read!(middle_record) == previous
  end

  # Adoption: a Hex dependency defining `compile: ["compile --warnings-as-errors"]`
  # is accepted (a flag-only self-alias runs the built-in task), a replacing
  # alias is refused, and an alias-implemented prefix stage (as in
  # file_system) is accepted.
  test "a dependency's flag-only compile self-alias and alias prefix stage are accepted",
       context do
    file = Path.join(context.dep, "mix.exs")
    original = File.read!(file)

    File.write!(
      file,
      String.replace(
        original,
        "app: :stored_dependency,",
        ~s(app: :stored_dependency, aliases: [compile: ["compile --warnings-as-errors"]],)
      )
    )

    {status, json, output} = Fixture.lint(context.dir)
    assert status == if(diagnostic_only?(), do: 2, else: 0), output
    assert json != nil
    assert read(context.dep_record)["compilers"] == ~w(yecc leex erlang elixir app)

    File.write!(
      file,
      String.replace(
        original,
        "app: :stored_dependency,",
        ~s(app: :stored_dependency, aliases: [compile: ["compile", "loadpaths"]],)
      )
    )

    {status, json, output} = Fixture.lint(context.dir)
    assert status == 2, output
    assert json == nil
    assert output =~ "unsupported compiler pipeline for stored_dependency: alias compile ", output
    refute File.exists?(context.record)

    File.write!(
      file,
      String.replace(
        original,
        "app: :stored_dependency,",
        "app: :stored_dependency, compilers: [:watcher] ++ Mix.compilers(), " <>
          ~s(aliases: ["compile.watcher": fn _ -> :ok end],)
      )
    )

    {status, json, output} = Fixture.lint(context.dir)
    assert status == if(diagnostic_only?(), do: 2, else: 0), output
    assert json != nil
    assert read(context.dep_record)["compilers"] == ~w(yecc leex watcher erlang elixir app)
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
    assert output =~ "stage :restore_cache runs after :erlang"
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

  # Makes the middle dependency a git (fetchable) dependency of the consumer.
  defp use_git_middle!(context) do
    middle = Path.join(Path.dirname(context.dir), "middle")
    file = Path.join(middle, "mix.exs")
    dependency = Path.join(Path.dirname(context.dir), "dependency")

    File.write!(
      file,
      String.replace(File.read!(file), inspect("../dependency"), inspect(dependency))
    )

    for args <- [
          ~w(init -q .),
          ~w(add -A),
          ~w(-c user.email=t@example.com -c user.name=t commit -qm m)
        ] do
      {_, 0} = System.cmd("git", args, cd: middle, stderr_to_stdout: true)
    end

    consumer = Path.join(context.dir, "mix.exs")

    File.write!(
      consumer,
      String.replace(
        File.read!(consumer),
        ~s({:middle_dependency, path: "../middle"}),
        "{:middle_dependency, git: #{inspect(middle)}}"
      )
    )
  end

  # Review (high): the manifest fix above called Mix.Dep.ElixirSCM.update/4,
  # which Elixir 1.20 does not have (update/3 there), and the API check
  # made every run on the 1.20 lane exit 2 before compiling anything.
  @tag :cross_compiler
  test "a fetchable dependency stays up to date under the other qualified compiler", context do
    other = System.get_env("SPEC_LINT_OTHER_ELIXIR") || flunk("set SPEC_LINT_OTHER_ELIXIR")
    use_git_middle!(context)

    mix = fn args ->
      System.cmd(Path.join(other, "mix"), args,
        cd: context.dir,
        env: Fixture.env([{"PATH", other <> ":" <> System.get_env("PATH")}]),
        stderr_to_stdout: true
      )
    end

    {revision, 0} =
      System.cmd(Path.join(other, "elixir"), ["-e", "IO.write(System.build_info()[:revision])"])

    expected = if String.starts_with?(revision, "648b2a9"), do: 2, else: 0
    lint = ["spec_lint", "--ci", "--format", "json", "--output", "other.json"]

    {_output, 0} = mix.(["deps.get"])
    {output, status} = mix.(lint)
    refute output =~ "evidence API is unavailable", output
    assert status == expected, output
    assert File.exists?(Path.join(context.dir, "other.json"))

    middle_record =
      Path.join(context.dir, "_build/dev/lib/middle_dependency/.mix/spec_lint.build")

    previous = File.read!(middle_record)
    {output, 0} = mix.(["deps"])
    refute output =~ "outdated", output

    {output, ^status} = mix.(lint)
    refute output =~ "recompiling", output
    assert File.read!(middle_record) == previous
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
