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
  that ran (`SpecLint.Compiler.capabilities/0`), and the SHA-256 of every
  BEAM file in the ebin at that moment. An application's artifacts are:

    * `:verified` - the record names the running build and every BEAM file
      is as recorded;
    * `:unrecorded` - there is no record (a build SpecLint's tasks did not
      make, such as an explicit ebin given to `bench/run_on_ebin.exs`);
    * `{:mismatch, reason}` - the record names another build, a BEAM file
      was added or changed since it was written (something else compiled
      it), or the record cannot be read. A recorded BEAM file that is gone
      is not a mismatch here: `SpecLint.Project` reports deleted BEAM files
      as an incomplete build, which a recompile must not hide.

  The Mix tasks recompile with `--force` unless every owned application is
  `:verified`, so a build they did not record, or one another build
  touched, is rebuilt by the running compiler before it is analysed.
  `SpecLint.Run` refuses an application in `{:mismatch, _}` (exit 2).
  Dependencies are not recorded: Mix recompiles them only when the Elixir
  version changes, and their chunks can still influence the signatures
  the running compiler infers for the project.
  """

  alias SpecLint.{Compiler, Project}

  @file_name "spec_lint.build"
  @version 1

  @typedoc "Why a record does not match the running build and the ebin."
  @type mismatch ::
          {:other_build, String.t() | nil, String.t() | nil}
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
      "build_digest" => Map.get(capabilities, :build_digest),
      "beams" => beams(app)
    }

    file = path(app)

    with :ok <- File.mkdir_p(Path.dirname(file)) do
      File.write(file, JSON.encode!(record))
    end
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

    if same_build? do
      found = beams(app)

      case changed(record["beams"], found) do
        [] -> :verified
        files -> {:mismatch, {:changed_beams, files}}
      end
    else
      {:mismatch, {:other_build, record["adapter"], record["build_digest"]}}
    end
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
