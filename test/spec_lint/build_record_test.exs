defmodule SpecLint.BuildRecordTest do
  # BEAM files produced by another compiler build (Milestone 2 review): two
  # qualified builds of 1.21.0-dev share the checker chunk version and
  # System.version(), so Mix keeps the other build's artifacts and SpecLint
  # analysed them under the running adapter's id. The build record ties an
  # application's artifacts to the build that produced them; since Milestone
  # 3 also to the compiler line (1.20 or 1.21).
  use ExUnit.Case, async: true

  import SpecLint.TestHelpers

  alias SpecLint.{Beam, BuildRecord, Compiler, Config, Project, Run}
  alias SpecLint.BuildRecord.Capture
  alias SpecLint.Fixtures.Compare
  alias SpecLint.Report.Json

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    ebin = Path.join(dir, "lib/fx/ebin")
    File.mkdir_p!(ebin)
    File.cp!(beam_path(Compare), Path.join(ebin, "#{Compare}.beam"))
    project = Project.from_ebins([{:fx, ebin}], dir)
    {:ok, capabilities} = Compiler.preflight_once()
    [app] = project.apps
    %{project: project, app: app, capabilities: capabilities, ebin: ebin}
  end

  defp run(project), do: Run.execute(project, %Config{baseline: "missing.json"}, ci: true)

  test "only readable Erlang artifacts without ExCk are exempt", %{tmp_dir: dir} do
    ebin = Path.join(dir, "erlang")
    File.mkdir_p!(ebin)
    source = Path.join(dir, "erlang_dependency_probe.erl")
    File.write!(source, "-module(erlang_dependency_probe). -export([tag/0]). tag() -> ok.")

    assert {:ok, :erlang_dependency_probe, bytes} =
             :compile.file(String.to_charlist(source), [:binary])

    File.write!(Path.join(ebin, "erlang_dependency_probe.beam"), bytes)
    refute BuildRecord.elixir_artifacts?(ebin)

    File.write!(Path.join(ebin, "invalid.beam"), "not a BEAM")
    assert BuildRecord.elixir_artifacts?(ebin)
  end

  test "a malformed ExCk remains an Elixir artifact requiring provenance", %{
    app: app,
    tmp_dir: dir
  } do
    original = beam_path(Compare)
    {:ok, _module, chunks} = :beam_lib.all_chunks(String.to_charlist(original))
    chunks = List.keyreplace(chunks, ~c"ExCk", 0, {~c"ExCk", <<0, 1, 2>>})
    {:ok, bytes} = :beam_lib.build_module(chunks)
    File.write!(Path.join(app.ebin, "#{Compare}.beam"), bytes)
    assert :error = Beam.checker_version(Path.join(app.ebin, "#{Compare}.beam"))
    assert BuildRecord.elixir_artifacts?(app.ebin)

    stripped = Path.join(dir, "stripped")
    File.mkdir_p!(stripped)
    {:ok, bytes} = :beam_lib.build_module(List.keydelete(chunks, ~c"ExCk", 0))
    File.write!(Path.join(stripped, "#{Compare}.beam"), bytes)
    assert BuildRecord.elixir_artifacts?(stripped)
  end

  test "missing compiler evidence API fails closed with exit status 2" do
    error =
      assert_raise Mix.Error, ~r/compiler artifact evidence API is unavailable/, fn ->
        Capture.start(SpecLint.MissingCompilerEvidenceAPI)
      end

    assert error.mix == 2
  end

  test "evidence rejects unproduced artifacts without replacing a record",
       %{app: app, capabilities: capabilities} do
    assert {:error, {:unverified_beams, [file]}} = BuildRecord.write(app, capabilities, %{})
    assert file == "#{Compare}.beam"
    refute File.exists?(BuildRecord.path(app))
    assert :ok = BuildRecord.write(app, capabilities)
    previous = File.read!(BuildRecord.path(app))
    assert {:error, {:unverified_beams, [_]}} = BuildRecord.write(app, capabilities, %{})
    assert File.read!(BuildRecord.path(app)) == previous
  end

  test "legacy app-wide records are not accepted as artifact evidence",
       %{app: app, capabilities: capabilities} do
    assert :ok = BuildRecord.write(app, capabilities)
    record = BuildRecord.path(app) |> File.read!() |> JSON.decode!()
    File.write!(BuildRecord.path(app), JSON.encode!(%{record | "version" => 1}))
    assert BuildRecord.status(app, capabilities) == {:mismatch, :invalid_record}
    assert BuildRecord.verified_beams(app, capabilities) == %{}
  end

  test "a build without a record is analysed and reported as unrecorded", %{project: project} do
    assert {:ok, run} = run(project)
    assert run.completion == :complete
    assert run.artifacts == [fx: :unrecorded]
    artifacts = Json.envelope(run)["artifacts"]
    assert artifacts["unrecorded"] == ["fx"]
    assert artifacts["recorded"] == []
    assert artifacts["build_digest"] == run.capabilities.build_digest
  end

  test "a build recorded for the running compiler is verified",
       %{project: project, app: app, capabilities: capabilities} do
    assert :ok = BuildRecord.write(app, capabilities)
    assert BuildRecord.path(app) == Path.join(Path.dirname(app.ebin), ".mix/spec_lint.build")
    assert BuildRecord.status(app, capabilities) == :verified
    assert {:ok, run} = run(project)
    assert run.completion == :complete
    assert Json.envelope(run)["artifacts"]["recorded"] == ["fx"]
  end

  test "a build recorded for another compiler build is an incomplete build (exit 2)",
       %{project: project, app: app, capabilities: capabilities} do
    other = %{capabilities | adapter_id: "1.21.0-dev+648b2a9", build_digest: "0123456789abcdef"}
    other = if other == capabilities, do: %{other | adapter_id: "other"}, else: other
    assert :ok = BuildRecord.write(app, other)

    assert {:mismatch, {:other_build, _adapter, "0123456789abcdef"}} =
             BuildRecord.status(app, capabilities)

    assert {:error, message} = run(project)
    assert message =~ "incomplete build: BEAM files not produced by the running compiler"
    assert message =~ "fx: compiled by another compiler build"
    assert message =~ "build 0123456789ab"

    # Only the build digest differs: a modified build of the same revision.
    assert :ok = BuildRecord.write(app, %{capabilities | build_digest: "fedcba9876543210"})
    assert {:error, _message} = run(project)
  end

  test "a build recorded by another compiler line is an incomplete build (exit 2)",
       %{project: project, app: app, capabilities: capabilities} do
    # Milestone 3: a 1.21 artifact under 1.20 and the reverse. The record
    # names the other line's checker chunk version and adapter.
    [other_adapter] = Compiler.adapters() -- [capabilities.adapter]

    other = %{
      capabilities
      | adapter: other_adapter,
        adapter_id: "other-line+0000000",
        elixir_version: "other-line",
        checker_version: other_adapter.qualified_checker_version(),
        build_digest: "0123456789abcdef"
    }

    assert :ok = BuildRecord.write(app, other)
    checker = Atom.to_string(other_adapter.qualified_checker_version())
    module = inspect(other_adapter)

    assert BuildRecord.status(app, capabilities) ==
             {:mismatch, {:other_compiler, "other-line+0000000", checker, module}}

    assert {:error, message} = run(project)
    assert message =~ "incomplete build: BEAM files not produced by the running compiler"
    assert message =~ "(#{capabilities.adapter_id})"

    assert message =~
             "fx: compiled by another compiler line (other-line+0000000, checker #{checker}"

    assert message =~ "adapter #{module}), whose artifacts the running adapter cannot read"

    # A record written before Milestone 3 (no checker version or adapter
    # module) naming another adapter id is another build.
    record = BuildRecord.path(app) |> File.read!() |> JSON.decode!()
    legacy = Map.drop(record, ["checker_version", "adapter_module", "elixir"])
    File.write!(BuildRecord.path(app), JSON.encode!(legacy))

    assert {:mismatch, {:other_build, "other-line+0000000", "0123456789abcdef"}} =
             BuildRecord.status(app, capabilities)
  end

  test "a BEAM file added or changed after the record is a mismatch, a deleted one is not",
       %{project: project, app: app, capabilities: capabilities, ebin: ebin, tmp_dir: dir} do
    assert :ok = BuildRecord.write(app, capabilities)

    changed =
      rebuild_beam(Compare, Path.join(dir, "other"), fn chunks ->
        {~c"ExCk", bytes} = List.keyfind(chunks, ~c"ExCk", 0)
        {version, contents} = :erlang.binary_to_term(bytes)
        contents = %{contents | exports: Enum.reverse(contents.exports)}

        List.keyreplace(
          chunks,
          ~c"ExCk",
          0,
          {~c"ExCk", :erlang.term_to_binary({version, contents})}
        )
      end)

    File.cp!(changed, Path.join(ebin, "#{Compare}.beam"))

    assert BuildRecord.status(app, capabilities) ==
             {:mismatch, {:changed_beams, ["#{Compare}.beam"]}}

    assert {:error, message} = run(project)
    assert message =~ "BEAM files changed after SpecLint recorded the build"

    # Deleted BEAM files are Project's incomplete build, not a reason to
    # recompile silently.
    File.rm!(Path.join(ebin, "#{Compare}.beam"))
    assert BuildRecord.status(app, capabilities) == :verified
  end

  test "an unreadable record is a mismatch", %{project: project, app: app, capabilities: caps} do
    File.mkdir_p!(Path.dirname(BuildRecord.path(app)))
    File.write!(BuildRecord.path(app), "{not json")
    assert BuildRecord.status(app, caps) == {:mismatch, :invalid_record}
    assert {:error, message} = run(project)
    assert message =~ "unreadable build record"
  end

  test "reports tell apart two BEAMs whose beam_lib MD5 is the same but whose ExCk differs",
       %{tmp_dir: dir} do
    original = beam_path(Compare)

    changed =
      rebuild_beam(Compare, Path.join(dir, "other"), fn chunks ->
        {~c"ExCk", bytes} = List.keyfind(chunks, ~c"ExCk", 0)
        {version, contents} = :erlang.binary_to_term(bytes)
        contents = %{contents | exports: tl(contents.exports)}

        List.keyreplace(
          chunks,
          ~c"ExCk",
          0,
          {~c"ExCk", :erlang.term_to_binary({version, contents})}
        )
      end)

    {md5, exck} = Beam.identity(original)
    {changed_md5, changed_exck} = Beam.identity(changed)
    assert md5 == changed_md5
    assert byte_size(exck) == 64
    assert exck != changed_exck

    project = Project.from_ebins([{:fx, Path.dirname(changed)}], dir)
    assert {:ok, run} = run(project)
    assert [%{"md5" => ^md5, "exck" => ^changed_exck}] = Json.envelope(run)["beams"]
  end
end
