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
  `:verified`, so a build they did not record, or one another build
  touched, is rebuilt by the running compiler before it is analysed.
  `SpecLint.Run` refuses an application in `{:mismatch, _}` (exit 2).

  Dependencies are not recorded: Mix recompiles them only when the Elixir
  version changes, and their chunks influence the signatures the running
  compiler infers for the project (a checker ignores a chunk of another
  version, so calls into the dependency become `dynamic()`).
  `foreign_dependencies/2` finds dependency BEAM files whose chunk version
  differs from the running compiler's, which the Mix tasks refuse (exit 2;
  such a mixed build needs `--no-deps-check`, a shared or stale build
  directory, or vendored BEAM files). A dependency built by another build
  of the running line writes the same chunk version and is not detected
  (DESIGN.md 5.2).
  """

  alias SpecLint.{Beam, Compiler, Project}

  @file_name "spec_lint.build"
  @version 1

  @typedoc "Why a record does not match the running build and the ebin."
  @type mismatch ::
          {:other_compiler, String.t() | nil, String.t(), String.t() | nil}
          | {:other_build, String.t() | nil, String.t() | nil}
          | {:changed_beams, [String.t()]}
          | :invalid_record

  @typedoc "Whether an application's artifacts were produced by the running build."
  @type status :: :verified | :unrecorded | {:mismatch, mismatch()}

  @doc "The record file of `app`: `.mix/spec_lint.build` next to its ebin."
  @spec path(Project.app()) :: String.t()
  def path(%{ebin: ebin}), do: Path.join([Path.dirname(ebin), ".mix", @file_name])

  @doc "Records that the running build (`capabilities`) produced `app`'s BEAM files."
  @spec write(Project.app(), Compiler.capabilities()) :: :ok | {:error, File.posix()}
  def write(app, capabilities) do
    record = %{
      "version" => @version,
      "adapter" => capabilities.adapter_id,
      "adapter_module" => inspect(capabilities.adapter),
      "elixir" => capabilities.elixir_version,
      "checker_version" => Atom.to_string(capabilities.checker_version),
      "build_digest" => Map.get(capabilities, :build_digest),
      "beams" => beams(app)
    }

    file = path(app)

    with :ok <- File.mkdir_p(Path.dirname(file)) do
      File.write(file, JSON.encode!(record))
    end
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
      {:ok, %{"version" => @version, "beams" => beams} = record} when is_map(beams) ->
        {:ok, record}

      _other ->
        :error
    end
  end

  defp compare(record, app, capabilities) do
    same_build? =
      record["adapter"] == capabilities.adapter_id and
        record["build_digest"] == Map.get(capabilities, :build_digest)

    cond do
      same_build? ->
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
