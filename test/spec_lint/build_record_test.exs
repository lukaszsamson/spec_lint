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
    assert BuildRecord.status(app, capabilities, Mix.compilers()) == {:mismatch, :invalid_record}
    assert BuildRecord.verified_beams(app, capabilities, Mix.compilers()) == %{}
  end

  test "version 3 records without a compiler pipeline require a rebuild",
       %{app: app, capabilities: capabilities} do
    assert :ok = BuildRecord.write(app, capabilities)
    record = BuildRecord.path(app) |> File.read!() |> JSON.decode!()
    assert record["version"] == BuildRecord.version()
    legacy = record |> Map.delete("compilers") |> Map.put("version", BuildRecord.version() - 1)
    File.write!(BuildRecord.path(app), JSON.encode!(legacy))
    assert BuildRecord.status(app, capabilities) == {:mismatch, :invalid_record}
    assert BuildRecord.verified_beams(app, capabilities, Mix.compilers()) == %{}
  end

  test "supported compiler pipelines: generators and custom stages before :erlang" do
    suffix = [:erlang, :elixir, :app]

    for prefix <- [
          [:yecc, :leex],
          [:leex, :yecc],
          [:yecc, :leex, :yecc],
          [:leex, :leex, :yecc],
          [:elixir_make, :yecc, :leex],
          [:yecc, :leex, :phoenix_swagger, :file_system],
          [:leex, :custom, :yecc, :custom]
        ] do
      assert BuildRecord.check_pipeline(prefix ++ suffix) == :ok, inspect(prefix)
    end

    for {compilers, message} <- [
          {[:yecc, :leex], "missing built-in stage :erlang"},
          {[:leex, :erlang, :elixir, :app], "missing built-in stage :yecc"},
          {[:yecc, :leex, :erlang, :app], "missing built-in stage :elixir"},
          {[:yecc, :leex, :elixir, :erlang, :app], "built-in stage :elixir runs before :erlang"},
          {[:yecc, :leex, :erlang, :app, :elixir],
           "built-in stage :app is repeated or out of order"},
          {[:yecc, :leex, :erlang, :elixir, :app, :elixir],
           "built-in stage :elixir is repeated or out of order"},
          {[:yecc, :leex, :erlang, :erlang, :elixir, :app],
           "built-in stage :erlang is repeated or out of order"},
          {[:yecc, :leex, :erlang, :elixir, :app, :cache], "stage :cache runs after :erlang"},
          {[:yecc, :leex, :erlang, :cache, :elixir, :app], "stage :cache runs after :erlang"},
          {[:yecc, :erlang, :leex, :elixir, :app], "stage :leex runs after :erlang"},
          {[:yecc, :leex, :cache, :erlang, :cache, :elixir, :app],
           "stage :cache runs after :erlang"},
          {[:yecc, :leex, :erlang, :elixir], "missing built-in stage :app"},
          {[], "missing built-in stage :yecc"}
        ] do
      assert {:error, reason} = BuildRecord.check_pipeline(compilers)
      assert reason =~ message, inspect(compilers)
    end
  end

  test "a record under another compiler pipeline is stale and lends no evidence",
       %{app: app, capabilities: capabilities} do
    pipeline = [:gen, :yecc, :leex, :erlang, :elixir, :app]
    assert BuildRecord.status(app, capabilities, pipeline) == :unrecorded
    evidence = BuildRecord.compiled_beams(app, MapSet.new([Compare]))
    assert :ok = BuildRecord.write(app, capabilities, evidence, %{}, pipeline)
    assert BuildRecord.status(app, capabilities, pipeline) == :verified
    assert map_size(BuildRecord.verified_beams(app, capabilities, pipeline)) == 1

    changed = [:other | pipeline]

    assert BuildRecord.status(app, capabilities, changed) ==
             {:mismatch,
              {:changed_pipeline, Enum.map(pipeline, &Atom.to_string/1),
               Enum.map(changed, &Atom.to_string/1)}}

    assert BuildRecord.describe(BuildRecord.status(app, capabilities, changed)) =~
             "compiler pipeline changed"

    assert BuildRecord.verified_beams(app, capabilities, changed) == %{}
    # status/2 (SpecLint.Run) checks artifacts, not the pipeline
    # (documented: the Mix task rebuilds on a changed pipeline first).
    assert BuildRecord.status(app, capabilities) == :verified

    # A changed artifact is reported as such under any pipeline.
    File.write!(Path.join(app.ebin, "Elixir.Extra.beam"), "not recorded")

    assert {:mismatch, {:changed_beams, ["Elixir.Extra.beam"]}} =
             BuildRecord.status(app, capabilities, pipeline)

    File.rm!(Path.join(app.ebin, "Elixir.Extra.beam"))

    # An explicit attestation names no pipeline and matches none.
    assert :ok = BuildRecord.write(app, capabilities)

    assert {:mismatch, {:changed_pipeline, nil, _}} =
             BuildRecord.status(app, capabilities, pipeline)

    assert BuildRecord.verified_beams(app, capabilities, pipeline) == %{}
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
