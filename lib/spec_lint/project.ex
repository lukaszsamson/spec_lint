defmodule SpecLint.Project do
  @moduledoc """
  The owned BEAM files of a Mix project (DESIGN.md sections 5 and 8).

  Owned means the project's own applications: the current app, or every
  child of an umbrella, each read from its ebin under the Mix build path.
  Dependencies are never lint targets. Modules are discovered from the
  build path, never from loaded modules. `MIX_ENV` and `MIX_TARGET` are
  recorded for the report.

  `current/0` reads the running Mix project; `from_ebins/2` builds a
  project from explicit ebin directories (for scripts such as
  `bench/run_on_ebin.exs`).

  A missing compile path is not the same as an empty one:
  `check_build_paths/1` reports `{:error, :missing_build_path}` when the
  ebin directory of an owned application does not exist (nothing was
  compiled there, or the path is wrong), which `SpecLint.Run` turns into a
  configuration error (exit 2). An ebin that exists but holds no BEAM file
  is a project with zero specs: the run succeeds and says so.

  An ebin that exists but lost some of its BEAM files (deleted by hand, or
  a partial `_build` cache restore) is not a smaller project either. Mix
  does not rebuild them: its compile manifest still says the build is up
  to date. `check_build_paths/1` reports `{:error, :missing_beams}` when a
  module the build lists has no `.beam` file in the ebin
  (`missing_modules/1`). It reports `{:error, :module_mismatch}` when a
  BEAM file's embedded module differs from its filename, and
  `{:error, :invalid_beam}` when a file cannot be decoded as a BEAM. BEAM
  files are decoded from their contents (`SpecLint.Beam.chunks/3`), so a
  corrupt file under a path longer than 255 characters is reported like
  any other, not a crash. The build's
  module list comes from:

    * for a project from `current/0`, the Elixir compiler's manifest
      (`.mix/compile.elixir` next to the ebin), which Mix updates whenever
      it removes a module. It is read with
      `Mix.Compilers.Elixir.read_manifest/1`, an internal Mix function of
      the pinned toolchain;
    * otherwise (no readable manifest, or that function is missing), the `modules`
      key of the application resource file `<app>.app` in the ebin, which
      every Mix application has. It is not used when the manifest can be
      read: Mix rewrites it only when the ebin's modification time is
      newer than its own (one-second resolution), so right after a module
      is deleted it can still list it. `read_manifest/1` returns `{[], []}`
      for an invalid manifest; that result also falls back to the `.app`
      file. A valid empty manifest returns `{%{}, %{}}` and takes precedence
      over a possibly stale `.app` file.

  An owned Mix app has a `:manifest` path in the project description. When
  neither that manifest nor the `.app` file gives a readable module list,
  `check_build_paths/1` reports `{:error, :missing_module_inventory}` rather
  than treating absent BEAM files as a legitimate empty project. Explicit
  `from_ebins/2` projects have no manifest and may have no `.app` file.
  """

  alias Mix.Compilers.Elixir, as: ElixirCompiler
  alias SpecLint.Beam

  @typedoc """
  One owned application: its ebin directory and, for a Mix project, the
  path of its Elixir compile manifest.
  """
  @type app :: %{
          required(:app) => atom(),
          required(:ebin) => String.t(),
          optional(:manifest) => String.t()
        }

  @typedoc "The modules of one application's build that have no BEAM file."
  @type missing :: %{app: atom(), ebin: String.t(), modules: [module()]}

  @typedoc "A BEAM whose filename and embedded module disagree."
  @type mismatch :: %{app: atom(), path: String.t(), expected: String.t(), found: module()}

  @typedoc "A file with a `.beam` suffix that cannot be decoded as a BEAM."
  @type invalid :: %{app: atom(), path: String.t(), reason: term()}

  @type t :: %__MODULE__{
          root: String.t(),
          apps: [app()],
          umbrella?: boolean(),
          mix_env: String.t() | nil,
          mix_target: String.t() | nil
        }

  @enforce_keys [:root, :apps]
  defstruct [:root, :apps, umbrella?: false, mix_env: nil, mix_target: nil]

  @doc """
  The current Mix project. Must be called after compilation, from inside a
  Mix task.
  """
  @spec current() :: t()
  def current do
    root = File.cwd!()

    apps =
      if Mix.Project.umbrella?() do
        build = Mix.Project.build_path()

        for {app, _path} <- Enum.sort(Mix.Project.apps_paths() || %{}) do
          dir = Path.join([build, "lib", Atom.to_string(app)])

          %{
            app: app,
            ebin: Path.join(dir, "ebin"),
            manifest: Path.join([dir, ".mix", "compile.elixir"])
          }
        end
      else
        [
          %{
            app: Mix.Project.config()[:app],
            ebin: Mix.Project.compile_path(),
            manifest: Path.join(Mix.Project.manifest_path(), "compile.elixir")
          }
        ]
      end

    %__MODULE__{
      root: root,
      apps: apps,
      umbrella?: Mix.Project.umbrella?(),
      mix_env: Atom.to_string(Mix.env()),
      mix_target: Atom.to_string(Mix.target())
    }
  end

  @doc """
  A project from explicit `{app, ebin}` pairs, rooted at `root` (paths in
  output are relative to it).
  """
  @spec from_ebins([{atom(), Path.t()}], Path.t()) :: t()
  def from_ebins(ebins, root) do
    %__MODULE__{
      root: Path.expand(root),
      apps: for({app, ebin} <- ebins, do: %{app: app, ebin: Path.expand(ebin)})
    }
  end

  @doc """
  Restricts the project to the applications in `apps` (all when `[]`).
  An app that is not owned is an error.
  """
  @spec select_apps(t(), [atom()]) :: {:ok, t()} | {:error, String.t()}
  def select_apps(project, []), do: {:ok, project}

  def select_apps(project, apps) do
    owned = Enum.map(project.apps, & &1.app)

    case apps -- owned do
      [] ->
        {:ok, %{project | apps: Enum.filter(project.apps, &(&1.app in apps))}}

      unknown ->
        {:error,
         "--app #{Enum.map_join(unknown, ", ", &Atom.to_string/1)} matches no owned " <>
           "application (owned: #{Enum.map_join(owned, ", ", &Atom.to_string/1)})"}
    end
  end

  @doc """
  `:ok` when the ebin directory of every application in `project` exists
  and holds a BEAM file for every module its build lists;
  `{:error, :missing_build_path}` when an ebin does not exist
  (`missing_build_paths/1` lists the applications), and
  `{:error, :missing_beams}` when a listed module has no BEAM file
  (`missing_modules/1`), and `{:error, :module_mismatch}` when an existing
  BEAM's embedded module does not match its filename (`mismatched_modules/1`),
  or `{:error, :invalid_beam}` for an unreadable or invalid BEAM
  (`invalid_beams/1`).
  An owned Mix app whose manifest and `.app` file are both unreadable has
  `{:error, :missing_module_inventory}` (`missing_module_inventories/1`).
  An existing ebin without BEAM files whose build
  lists no module is `:ok`: that is a project with zero specs, not a
  missing build.
  """
  @spec check_build_paths(t()) ::
          :ok
          | {:error,
             :missing_build_path
             | :missing_module_inventory
             | :missing_beams
             | :invalid_beam
             | :module_mismatch}
  def check_build_paths(project) do
    cond do
      missing_build_paths(project) != [] -> {:error, :missing_build_path}
      missing_module_inventories(project) != [] -> {:error, :missing_module_inventory}
      missing_modules(project) != [] -> {:error, :missing_beams}
      invalid_beams(project) != [] -> {:error, :invalid_beam}
      mismatched_modules(project) != [] -> {:error, :module_mismatch}
      true -> :ok
    end
  end

  @doc "The applications of `project` whose ebin directory does not exist."
  @spec missing_build_paths(t()) :: [app()]
  def missing_build_paths(project), do: Enum.reject(project.apps, &File.dir?(&1.ebin))

  @doc """
  Per application whose ebin exists, the modules its build lists (its
  Elixir compile manifest, or else its `<app>.app` file; see the
  moduledoc) that have no BEAM file in the ebin. Applications with no
  missing module are left out.
  """
  @spec missing_modules(t()) :: [missing()]
  def missing_modules(project) do
    for app <- project.apps,
        File.dir?(app.ebin),
        missing = missing_in(app),
        missing != [],
        do: %{app: app.app, ebin: app.ebin, modules: missing}
  end

  @doc "Owned Mix apps for which neither the manifest nor the `.app` file gives a module list."
  @spec missing_module_inventories(t()) :: [app()]
  def missing_module_inventories(project) do
    for %{manifest: _} = app <- project.apps,
        File.dir?(app.ebin),
        module_inventory(app) == :error,
        do: app
  end

  @doc "Existing BEAM files whose embedded module disagrees with the filename."
  @spec mismatched_modules(t()) :: [mismatch()]
  def mismatched_modules(project) do
    for {app, path} <- beams(project),
        expected = Path.basename(path, ".beam"),
        {:ok, {found, _info}} <- [Beam.chunks(path, [:exports])],
        Atom.to_string(found) != expected,
        do: %{app: app, path: path, expected: expected, found: found}
  end

  @doc "Unreadable or invalid `.beam` files in the owned application ebins."
  @spec invalid_beams(t()) :: [invalid()]
  def invalid_beams(project) do
    for {app, path} <- beams(project),
        {:error, :beam_lib, reason} <- [Beam.chunks(path, [:exports])],
        do: %{app: app, path: path, reason: reason}
  end

  defp missing_in(app) do
    case module_inventory(app) do
      {:ok, modules} -> modules
      :error -> []
    end
    |> Enum.uniq()
    |> Enum.reject(&File.regular?(Path.join(app.ebin, Atom.to_string(&1) <> ".beam")))
    |> Enum.sort()
  end

  defp module_inventory(app) do
    case manifest_modules(app) do
      {:ok, _modules} = result -> result
      :error -> app_file_modules(app)
    end
  end

  defp app_file_modules(%{app: name, ebin: ebin}) when is_atom(name) and name != nil do
    path = Path.join(ebin, Atom.to_string(name) <> ".app")

    case :file.consult(String.to_charlist(path)) do
      {:ok, [{:application, ^name, properties}]} when is_list(properties) ->
        case Keyword.fetch(properties, :modules) do
          {:ok, modules} when is_list(modules) -> {:ok, Enum.filter(modules, &is_atom/1)}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp app_file_modules(_app), do: :error

  defp manifest_modules(%{manifest: path}) when is_binary(path) do
    if File.regular?(path) and Code.ensure_loaded?(ElixirCompiler) and
         function_exported?(ElixirCompiler, :read_manifest, 1) do
      path |> ElixirCompiler.read_manifest() |> manifest_entries()
    else
      :error
    end
  end

  defp manifest_modules(_app), do: :error

  # The qualified Mix compiler returns this sentinel for unreadable or
  # wrong-version manifests. A valid empty manifest has two empty maps.
  defp manifest_entries({[], []}), do: :error

  defp manifest_entries({modules, _sources}) when is_map(modules),
    do: {:ok, modules |> Map.keys() |> Enum.filter(&is_atom/1)}

  defp manifest_entries({modules, _sources}) when is_list(modules),
    do: {:ok, for({module, _} <- modules, is_atom(module), do: module)}

  defp manifest_entries(_other), do: :error

  @doc """
  The BEAM files of the project, sorted, as `{app, path}`. When `modules`
  is not empty only those modules' files are returned.
  """
  @spec beams(t(), [module()]) :: [{atom(), String.t()}]
  def beams(project, modules \\ []) do
    wanted = MapSet.new(modules, &(Atom.to_string(&1) <> ".beam"))

    for %{app: app, ebin: ebin} <- project.apps,
        path <- ebin |> Path.join("*.beam") |> Path.wildcard() |> Enum.sort(),
        modules == [] or MapSet.member?(wanted, Path.basename(path)),
        do: {app, path}
  end

  @doc "`path` relative to the project root when it is inside it."
  @spec relative(t(), String.t() | nil) :: String.t() | nil
  def relative(_project, nil), do: nil

  def relative(project, path) do
    case Path.relative_to(path, project.root) do
      relative when relative == path -> path
      relative -> relative
    end
  end

  @doc """
  Whether a relative source path matches any of the exclude globs. `**`
  matches any number of directories, `*` any characters except `/`, `?`
  one character except `/`.
  """
  @spec excluded?(String.t() | nil, [String.t()]) :: boolean()
  def excluded?(nil, _globs), do: false
  def excluded?(path, globs), do: Enum.any?(globs, &Regex.match?(glob_regex(&1), path))

  @doc "Compiles an exclude glob to an anchored regex."
  @spec glob_regex(String.t()) :: Regex.t()
  def glob_regex(glob) do
    source =
      glob
      |> String.graphemes()
      |> translate([])
      |> IO.iodata_to_binary()

    Regex.compile!("\\A" <> source <> "\\z")
  end

  defp translate(["*", "*", "/" | rest], acc), do: translate(rest, [acc, "(?:.*/)?"])
  defp translate(["*", "*" | rest], acc), do: translate(rest, [acc, ".*"])
  defp translate(["*" | rest], acc), do: translate(rest, [acc, "[^/]*"])
  defp translate(["?" | rest], acc), do: translate(rest, [acc, "[^/]"])
  defp translate([char | rest], acc), do: translate(rest, [acc, Regex.escape(char)])
  defp translate([], acc), do: acc
end
