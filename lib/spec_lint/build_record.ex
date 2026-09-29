defmodule SpecLint.BuildRecord do
  @moduledoc """
  Which compiler build produced an application's BEAM files (DESIGN.md
  section 6, "Artifacts from another build").

  Two builds of the same Elixir version write the same checker chunk
  version and the same `System.version()`, and Mix recompiles only when the
  version changes, so after switching between two qualified builds of
  `1.21.0-dev` a project keeps the other build's BEAM files. Their stored
  signatures are that build's, and analysing them under the running
  adapter would report the other build's verdict under this one's id.

  The record is a small JSON file next to Mix's own manifests,
  `<app build dir>/.mix/spec_lint.build`, written by the Mix tasks after
  they compile. It holds the adapter id and build digest of the compiler
  that ran (`SpecLint.Compiler.capabilities/0`), since Milestone 3 also its
  Elixir version, checker chunk version and adapter module, and the SHA-256
  of every BEAM file in the ebin at that moment. An application's
  artifacts are:

    * `:verified` - the record names the running build and every BEAM file
      is as recorded;
    * `:unrecorded` - there is no record (a build SpecLint's tasks did not
      make, such as an explicit ebin given to `bench/run_on_ebin.exs`);
    * `{:mismatch, reason}` - the record names another compiler line
      (`{:other_compiler, ...}`: another checker chunk version or adapter,
      such as a 1.21 build under 1.20; the running adapter cannot read its
      artifacts at all), another build of the running line
      (`{:other_build, ...}`), a BEAM file was added or changed since it was
      written (something else compiled it), or the record cannot be read. A recorded BEAM file that is gone
      is not a mismatch here: `SpecLint.Project` reports deleted BEAM files
      as an incomplete build, which a recompile must not hide.

  The Mix tasks recompile with `--force` unless every owned application is
  `:verified`. They record only modules reported as compiled by Mix's
  compiler events in this VM, or unchanged artifacts already verified for
  this compiler. A successful app-wide compile does not establish who
  produced orphan BEAM files: those cause exit 2 and are retained for the
  user to rebuild or remove explicitly. Only Mix's complete default
  compiler pipeline, without compile task aliases or replacements, is
  supported. Disabling a stage could leave stale source artifacts in an
  otherwise verified build. Dependency snapshots bind absolute ebin paths;
  moving a build tree invalidates them and requires a rebuild.
  Events identify module names, not
  output bytes, so a later custom compiler restoring cached BEAMs could
  otherwise have another compiler's output recorded as this build's.
  This is build provenance accounting, not a security boundary against
  project code modifying artifacts during compilation.
  Version 1 records did not establish per-artifact evidence and are
  invalidated, requiring a rebuild before they can be recorded again.
  `SpecLint.Run` refuses an application in `{:mismatch, _}` (exit 2).

  Source-backed Mix dependencies are recorded and checked in their actual
  dependency environment before owned applications compile. A stale or
  rebuilt dependency forces later dependencies and owned consumers to
  recompile, even when its code MD5 is unchanged: its checker signatures
  may have changed. Non-Mix dependencies without Elixir checker chunks
  (pure Erlang artifacts) do not need compiler-signature provenance;
  external Elixir artifacts with no supported source compiler fail closed.
  Version 1 and 2 records are invalidated so a previous record cannot retain
  inference based on an unverified dependency.
  """

  alias SpecLint.{Beam, Compiler, Project}

  @file_name "spec_lint.build"
  # Version 1 stamped every file in an ebin after an app-wide successful
  # compile, including orphan artifacts the compiler never rebuilt.
  # Version 2 verified owned outputs but could infer them from a dependency
  # compiled by another build of the same compiler line.
  @version 3

  @typedoc "Why a record does not match the running build and the ebin."
  @type mismatch ::
          {:other_compiler, String.t() | nil, String.t(), String.t() | nil}
          | {:other_build, String.t() | nil, String.t() | nil}
          | {:changed_beams, [String.t()]}
          | {:changed_dependencies, [String.t()]}
          | :invalid_record

  @typedoc "Whether an application's artifacts were produced by the running build."
  @type status :: :verified | :unrecorded | {:mismatch, mismatch()}

  @doc "The record file of `app`: `.mix/spec_lint.build` next to its ebin."
  @spec path(%{required(:ebin) => String.t(), optional(term()) => term()}) :: String.t()
  def path(%{ebin: ebin}), do: Path.join([Path.dirname(ebin), ".mix", @file_name])

  @doc """
  Explicitly attests that the caller produced all of `app`'s current BEAM
  files with `capabilities`. The Mix tasks use `write/3` with captured
  production evidence instead of this caller-supplied attestation.
  """
  @spec write(Project.app(), Compiler.capabilities()) :: :ok | {:error, File.posix()}
  def write(app, capabilities) do
    write(app, capabilities, beams(app))
  end

  @doc "Writes a record only if every artifact has the supplied production evidence."
  @spec write(Project.app(), Compiler.capabilities(), map()) ::
          :ok | {:error, File.posix() | {:unverified_beams, [String.t()]}}
  def write(app, capabilities, evidence), do: write(app, capabilities, evidence, %{})

  @doc "Writes production evidence together with the dependency inputs used for inference."
  @spec write(Project.app(), Compiler.capabilities(), map(), map()) ::
          :ok | {:error, File.posix() | {:unverified_beams, [String.t()]}}
  def write(app, capabilities, evidence, dependencies) do
    found = beams(app)

    case changed(evidence, found) do
      [] -> write_record(app, capabilities, found, dependencies)
      files -> {:error, {:unverified_beams, files}}
    end
  end

  @doc "Unchanged artifacts previously recorded for the running compiler build."
  @spec verified_beams(Project.app(), Compiler.capabilities()) :: map()
  def verified_beams(app, capabilities) do
    with {:ok, record} <- read(app),
         true <- same_build?(record, capabilities),
         [] <- changed_dependencies(record["dependencies"], capabilities) do
      Map.filter(beams(app), fn {file, digest} -> record["beams"][file] == digest end)
    else
      _ ->
        %{}
    end
  end

  @doc "Digests of artifacts whose modules were emitted by this compilation."
  @spec compiled_beams(Project.app(), MapSet.t()) :: map()
  def compiled_beams(app, modules) do
    files = MapSet.new(modules, &(Atom.to_string(&1) <> ".beam"))
    Map.filter(beams(app), fn {file, _digest} -> MapSet.member?(files, file) end)
  end

  @doc "Snapshot of a verified dependency record, binding its exact artifact bytes."
  @spec snapshot(Project.app()) :: %{String.t() => String.t()}
  def snapshot(app) do
    %{
      "ebin" => Path.expand(app.ebin),
      "record_sha256" => digest(File.read!(path(app)))
    }
  end

  defp write_record(app, capabilities, found, dependencies) do
    record = %{
      "version" => @version,
      "adapter" => capabilities.adapter_id,
      "adapter_module" => inspect(capabilities.adapter),
      "elixir" => capabilities.elixir_version,
      "checker_version" => Atom.to_string(capabilities.checker_version),
      "build_digest" => Map.get(capabilities, :build_digest),
      "beams" => found,
      "dependencies" => dependencies
    }

    file = path(app)

    with :ok <- File.mkdir_p(Path.dirname(file)) do
      File.write(file, JSON.encode!(record))
    end
  end

  @doc "Whether artifacts need Elixir provenance; unreadable BEAMs fail closed."
  @spec elixir_artifacts?(Path.t()) :: boolean()
  def elixir_artifacts?(ebin) do
    Enum.any?(Path.wildcard(Path.join(ebin, "*.beam")), fn path ->
      case Beam.chunks(path, [~c"ExCk"], [:allow_missing_chunks]) do
        {:ok, {module, [{~c"ExCk", :missing_chunk}]}} ->
          String.starts_with?(Atom.to_string(module), "Elixir.")

        {:ok, {_module, [{~c"ExCk", _bytes}]}} ->
          true

        _unreadable ->
          true
      end
    end)
  end

  @doc """
  The dependencies among `ebins` (`{app, ebin}` pairs) with BEAM files whose
  checker chunk version is not the running compiler's, with those versions.
  BEAM files without a checker chunk (Erlang modules) or that cannot be
  read are not counted.
  """
  @spec foreign_dependencies([{atom(), Path.t()}], Compiler.capabilities()) ::
          [{atom(), [String.t()]}]
  def foreign_dependencies(ebins, capabilities) do
    running = Atom.to_string(capabilities.checker_version)

    for {app, ebin} <- ebins,
        versions = chunk_versions(ebin) -- [running],
        versions != [],
        do: {app, versions}
  end

  defp chunk_versions(ebin) do
    for path <- ebin |> Path.join("*.beam") |> Path.wildcard(),
        {:ok, version} <- [Beam.checker_version(path)],
        uniq: true,
        do: version
  end

  @doc "The status of `app`'s artifacts against the running build (see the moduledoc)."
  @spec status(Project.app(), Compiler.capabilities()) :: status()
  def status(app, capabilities) do
    case read(app) do
      :missing ->
        :unrecorded

      {:ok, record} ->
        compare(record, app, capabilities)

      :error ->
        {:mismatch, :invalid_record}
    end
  end

  @doc "`status/2` of every application of `project`, as `{app, status}`."
  @spec statuses(Project.t(), Compiler.capabilities()) :: [{atom(), status()}]
  def statuses(project, capabilities),
    do: for(app <- project.apps, do: {app.app, status(app, capabilities)})

  @doc "A one-line explanation of a `{:mismatch, reason}` status."
  @spec describe({:mismatch, mismatch()}) :: String.t()
  def describe({:mismatch, {:other_compiler, adapter, checker_version, adapter_module}}),
    do:
      "compiled by another compiler line (#{adapter || "unknown"}, checker " <>
        "#{checker_version}, adapter #{adapter_module || "unknown"}), whose artifacts " <>
        "the running adapter cannot read"

  def describe({:mismatch, {:other_build, adapter, digest}}),
    do: "compiled by another compiler build (#{adapter || "unknown"}, build #{short(digest)})"

  def describe({:mismatch, {:changed_beams, files}}),
    do:
      "BEAM files changed after SpecLint recorded the build " <>
        "(#{Enum.join(Enum.take(files, 5), ", ")}#{if length(files) > 5, do: ", ...", else: ""})"

  def describe({:mismatch, {:changed_dependencies, apps}}),
    do: "dependency compiler artifacts changed after inference (#{Enum.join(apps, ", ")})"

  def describe({:mismatch, :invalid_record}), do: "unreadable build record #{@file_name}"

  defp short(nil), do: "unknown"
  defp short(digest), do: String.slice(digest, 0, 12)

  defp read(app) do
    case File.read(path(app)) do
      {:ok, contents} -> decode(contents)
      {:error, :enoent} -> :missing
      {:error, _reason} -> :error
    end
  end

  defp decode(contents) do
    case JSON.decode(contents) do
      {:ok, %{"version" => @version, "beams" => beams, "dependencies" => dependencies} = record}
      when is_map(beams) and is_map(dependencies) ->
        {:ok, record}

      _other ->
        :error
    end
  end

  defp compare(record, app, capabilities) do
    cond do
      same_build?(record, capabilities) and
          changed_dependencies(record["dependencies"], capabilities) != [] ->
        {:mismatch,
         {:changed_dependencies, changed_dependencies(record["dependencies"], capabilities)}}

      same_build?(record, capabilities) ->
        case changed(record["beams"], beams(app)) do
          [] -> :verified
          files -> {:mismatch, {:changed_beams, files}}
        end

      other_line?(record, capabilities) ->
        {:mismatch,
         {:other_compiler, record["adapter"], record["checker_version"], record["adapter_module"]}}

      true ->
        {:mismatch, {:other_build, record["adapter"], record["build_digest"]}}
    end
  end

  # Every record includes the entire previously verified dependency prefix,
  # so checking these snapshots directly also checks transitive inputs,
  # without recursively following record files (which could form cycles).
  defp changed_dependencies(dependencies, capabilities) do
    dependencies
    |> Enum.reject(fn {_app, snapshot} -> dependency_matches?(snapshot, capabilities) end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp dependency_matches?(%{"ebin" => ebin, "record_sha256" => expected}, capabilities)
       when is_binary(ebin) and is_binary(expected) do
    app = %{ebin: ebin}

    with {:ok, contents} <- File.read(path(app)),
         true <- digest(contents) == expected,
         {:ok, record} <- decode(contents) do
      same_build?(record, capabilities) and record["beams"] == beams(app)
    else
      _ -> false
    end
  end

  defp dependency_matches?(_snapshot, _capabilities), do: false

  defp digest(contents), do: :sha256 |> :crypto.hash(contents) |> Base.encode16(case: :lower)

  defp same_build?(record, capabilities) do
    record["adapter"] == capabilities.adapter_id and
      record["build_digest"] == Map.get(capabilities, :build_digest) and
      not other_line?(record, capabilities)
  end

  # Another compiler line: the record names another checker chunk version
  # or adapter. Records written before Milestone 3 name neither; they are
  # another build (both qualified builds then were one line).
  defp other_line?(record, capabilities) do
    checker = record["checker_version"]
    module = record["adapter_module"]

    (is_binary(checker) and checker != Atom.to_string(capabilities.checker_version)) or
      (is_binary(module) and module != inspect(capabilities.adapter))
  end

  # BEAM files present now that were not recorded or differ from the
  # record. A recorded file that is gone is not a mismatch: deleted BEAM
  # files are an incomplete build that SpecLint.Project reports (exit 2),
  # and a recompile must not paper over it.
  defp changed(recorded, found) do
    found
    |> Enum.reject(fn {file, digest} -> Map.get(recorded, file) == digest end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp beams(%{ebin: ebin}) do
    for path <- ebin |> Path.join("*.beam") |> Path.wildcard(),
        {:ok, contents} <- [File.read(path)],
        into: %{},
        do:
          {Path.basename(path), :sha256 |> :crypto.hash(contents) |> Base.encode16(case: :lower)}
  end
end
