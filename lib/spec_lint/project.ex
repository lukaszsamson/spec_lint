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
  """

  @typedoc "One owned application and its ebin directory."
  @type app :: %{app: atom(), ebin: String.t()}

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
          %{app: app, ebin: Path.join([build, "lib", Atom.to_string(app), "ebin"])}
        end
      else
        [%{app: Mix.Project.config()[:app], ebin: Mix.Project.compile_path()}]
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
