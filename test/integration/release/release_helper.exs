# Shared helpers of the release installation and upgrade tests (Milestone 5).
# Loaded with `Code.require_file/2` by the test files of this directory, so it
# stays out of `test/support` and out of the library's compile paths.
#
# Everything here drives the public Mix tasks (`mix spec_lint`,
# `mix spec_lint.baseline`) of a consumer project in a separate OS process,
# the way a user does. The consumer lives in the system temporary directory.
defmodule SpecLint.Release.Consumer do
  @moduledoc false

  alias SpecLint.ProjectFixture, as: Fixture

  @typedoc "A compiler under test: `nil` is the compiler running the suite, else its bin directory."
  @type bin :: String.t() | nil

  ## Sources

  @clean """
  defmodule Consumer do
    @spec greet(atom()) :: String.t()
    def greet(name) when is_atom(name), do: "hello " <> Atom.to_string(name)
  end
  """

  # Three gated SL001 findings: an atom returned as integer, a tuple element
  # and a map field. The map one has a different fingerprint on each compiler
  # line (the lines encode map types differently); the other two do not.
  @bad """
  defmodule Consumer.Bad do
    @spec size(atom()) :: integer()
    def size(name) when is_atom(name), do: name

    @spec wrap(atom()) :: {:ok, integer()}
    def wrap(name) when is_atom(name), do: {:ok, name}

    @spec shape(atom()) :: %{name: integer()}
    def shape(name) when is_atom(name), do: %{name: name}
  end
  """

  @spec clean_source() :: String.t()
  def clean_source, do: @clean

  @spec bad_source() :: String.t()
  def bad_source, do: @bad

  @doc "A fourth, independent gated finding."
  @spec worse_source() :: String.t()
  def worse_source do
    """
    defmodule Consumer.Worse do
      @spec label(atom()) :: integer()
      def label(name) when is_atom(name), do: Atom.to_string(name)
    end
    """
  end

  ## Dependencies

  @spec path_dep(String.t()) :: String.t()
  def path_dep(root \\ Fixture.root()),
    do: "{:spec_lint, path: #{inspect(root)}, only: [:dev, :test], runtime: false}"

  @spec git_dep(String.t()) :: String.t()
  def git_dep(url),
    do: "{:spec_lint, git: #{inspect(url)}, only: [:dev, :test], runtime: false}"

  @doc """
  A git repository holding a snapshot of the working tree's `lib`, `mix.exs`
  and `mix.lock` (so uncommitted changes are tested too), for a git
  dependency. Returns its `file://` URL.
  """
  @spec snapshot_repo!(String.t()) :: String.t()
  def snapshot_repo!(dir) do
    File.mkdir_p!(dir)

    for path <- ~w(lib mix.exs mix.lock),
        do: File.cp_r!(Path.join(Fixture.root(), path), Path.join(dir, path))

    git!(dir, ["init", "-q", "."])
    git!(dir, ["add", "-A"])

    git!(dir, ["-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-qm", "snapshot"])

    "file://" <> dir
  end

  @doc "Whether git revision `rev` is available in this checkout."
  @spec revision_available?(String.t()) :: boolean()
  def revision_available?(rev) do
    match?(
      {_, 0},
      System.cmd("git", ["cat-file", "-e", rev <> "^{commit}"],
        cd: Fixture.root(),
        stderr_to_stdout: true
      )
    )
  rescue
    _ -> false
  end

  @doc """
  Extracts the tracked `lib`, `mix.exs` and `mix.lock` of git revision `rev`
  of this repository into `dir`. `:error` when the revision is not available
  (a shallow clone, a source archive).
  """
  @spec extract_revision(String.t(), String.t()) :: :ok | :error
  def extract_revision(rev, dir) do
    root = Fixture.root()

    with {_, 0} <-
           System.cmd("git", ["cat-file", "-e", rev <> "^{commit}"],
             cd: root,
             stderr_to_stdout: true
           ),
         {tar, 0} <- System.cmd("git", ["archive", rev, "lib", "mix.exs", "mix.lock"], cd: root) do
      File.mkdir_p!(dir)
      tar_path = dir <> ".tar"
      File.write!(tar_path, tar)
      {_, 0} = System.cmd("tar", ["-xf", tar_path, "-C", dir])
      File.rm!(tar_path)
      :ok
    else
      _ -> :error
    end
  end

  defp git!(dir, args) do
    {output, status} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    if status != 0, do: raise("git #{Enum.join(args, " ")} failed: #{output}")
    :ok
  end

  ## Projects

  @doc """
  Writes a Mix project into a fresh directory and returns it. `dep` is the
  spec_lint dependency tuple as source text; `:source` replaces the project's
  one clean module.
  """
  @spec create!(String.t(), String.t(), keyword()) :: String.t()
  def create!(prefix, dep, opts \\ []) do
    dir = Fixture.tmp_dir!(prefix)
    Fixture.write!(dir, "mix.exs", mix_exs(dep))
    Fixture.write!(dir, "lib/consumer.ex", Keyword.get(opts, :source, @clean))
    dir
  end

  @spec mix_exs(String.t()) :: String.t()
  def mix_exs(dep) do
    """
    defmodule Consumer.MixProject do
      use Mix.Project

      def project do
        [app: :consumer, version: "0.1.0", deps: [#{dep}]]
      end
    end
    """
  end

  ## Running

  @doc """
  Runs `mix args` in `dir` with the compiler in `:bin` (default: the one
  running the suite). `:env` adds environment variables. Returns
  `{output, status}` with standard error merged into the output.
  """
  @spec mix(String.t(), [String.t()], keyword()) :: {String.t(), non_neg_integer()}
  def mix(dir, args, opts \\ []) do
    bin = Keyword.get(opts, :bin)
    env = Keyword.get(opts, :env, [])

    case bin do
      nil ->
        Fixture.mix(dir, args, env)

      bin ->
        System.cmd(Path.join(bin, "mix"), args,
          cd: dir,
          env: Fixture.env([{"PATH", bin <> ":" <> System.get_env("PATH")} | env]),
          stderr_to_stdout: true
        )
    end
  end

  @doc """
  `mix spec_lint --ci --format json --output report.json` plus `extra`;
  `{status, decoded report or nil, output}`.
  """
  @spec lint(String.t(), [String.t()], keyword()) :: {integer(), map() | nil, String.t()}
  def lint(dir, extra \\ [], opts \\ []) do
    report = Path.join(dir, "report.json")
    File.rm(report)

    {output, status} =
      mix(dir, ["spec_lint", "--ci", "--format", "json", "--output", report] ++ extra, opts)

    json = if File.exists?(report), do: report |> File.read!() |> JSON.decode!()
    {status, json, output}
  end

  @spec baseline_path(String.t()) :: String.t()
  def baseline_path(dir), do: Path.join(dir, ".spec_lint_baseline.json")

  @spec read_baseline!(String.t(), String.t() | nil) :: map()
  def read_baseline!(dir, path \\ nil),
    do: (path || baseline_path(dir)) |> File.read!() |> JSON.decode!()

  @spec write_baseline!(String.t(), map(), String.t() | nil) :: :ok
  def write_baseline!(dir, baseline, path \\ nil),
    do: File.write!(path || baseline_path(dir), JSON.encode!(baseline))

  ## Compiler identity

  @doc "The adapter id of the running compiler (`1.21.0-dev+c24c235`)."
  @spec adapter_id() :: String.t()
  def adapter_id, do: "#{System.version()}+#{revision()}"

  @spec revision() :: String.t()
  def revision, do: String.slice(System.build_info()[:revision], 0, 7)

  @spec checker_version() :: String.t()
  def checker_version, do: Atom.to_string(:elixir_erl.checker_version())

  @doc "The bin directory of the other qualified compiler, or `nil`."
  @spec other_bin() :: String.t() | nil
  def other_bin, do: System.get_env("SPEC_LINT_OTHER_ELIXIR")

  @doc "The bin directory of a compiler outside the support range (1.19), or `nil`."
  @spec unsupported_bin() :: String.t() | nil
  def unsupported_bin, do: System.get_env("SPEC_LINT_UNSUPPORTED_ELIXIR")

  @doc "The adapter id and checker chunk version of the compiler in `bin`."
  @spec identity(String.t()) :: {String.t(), String.t()}
  def identity(bin) do
    {output, 0} =
      System.cmd(Path.join(bin, "elixir"), [
        "-e",
        ~S|IO.write("#{System.version()}+#{String.slice(System.build_info()[:revision], 0, 7)} | <>
          ~S|#{:elixir_erl.checker_version()}")|
      ])

    [id, checker] = String.split(output, " ")
    {id, checker}
  end

  @doc "Whether the compilers in `bin` and the running one write different checker chunks."
  @spec other_line?(String.t()) :: boolean()
  def other_line?(bin), do: elem(identity(bin), 1) != checker_version()
end
