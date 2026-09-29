defmodule SpecLint.ProjectFixture do
  @moduledoc """
  Helpers for consumer integration tests: throw-away Mix projects that
  depend on this checkout and run `mix spec_lint` in a separate OS process.

  A fixture lives under the operating system's temporary directory, never
  inside the repository, and the test removes it (`tmp_dir!/1` and
  `on_exit/1`).
  """

  @root Path.expand("../..", __DIR__)

  @doc "The checkout the fixtures depend on."
  @spec root() :: String.t()
  def root, do: @root

  @doc "A fresh directory under the system temporary directory."
  @spec tmp_dir!(String.t()) :: String.t()
  def tmp_dir!(prefix) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "spec_lint-#{prefix}-#{System.os_time(:millisecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    dir
  end

  @doc "Writes `contents` to `path` (relative to `dir`), creating directories."
  @spec write!(String.t(), Path.t(), String.t()) :: :ok
  def write!(dir, path, contents) do
    full = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, contents)
  end

  @doc """
  The environment of a fixture's `mix` process: `MIX_ENV=dev`, and no
  `MIX_BUILD_PATH`, which would otherwise be inherited from a test run built
  into a separate build path (the upstream toolchain qualification) and put
  the fixture's build there.
  """
  @spec env([{String.t(), String.t()}]) :: [{String.t(), String.t() | nil}]
  def env(extra \\ []), do: [{"MIX_ENV", "dev"}, {"MIX_BUILD_PATH", nil} | extra]

  @doc "Runs `mix args` in `dir` under `env/1`, returning `{output, status}`."
  @spec mix(String.t(), [String.t()], [{String.t(), String.t()}]) :: {String.t(), integer()}
  def mix(dir, args, env \\ []) do
    System.cmd(System.find_executable("mix"), args,
      cd: dir,
      env: env(env),
      stderr_to_stdout: true
    )
  end

  @doc """
  Runs `mix spec_lint --ci --format json --output report.json` with `extra`
  options and returns `{exit_status, decoded_report_or_nil, output}`.
  """
  @spec lint(String.t(), [String.t()], [{String.t(), String.t()}]) ::
          {integer(), map() | nil, String.t()}
  def lint(dir, extra \\ [], env \\ []) do
    report = Path.join(dir, "report.json")
    File.rm(report)

    {output, status} =
      mix(dir, ["spec_lint", "--ci", "--format", "json", "--output", report] ++ extra, env)

    json = if File.exists?(report), do: report |> File.read!() |> JSON.decode!()
    {status, json, output}
  end

  @doc "The decoded baseline file of `dir`."
  @spec baseline!(String.t()) :: map()
  def baseline!(dir),
    do: dir |> Path.join(".spec_lint_baseline.json") |> File.read!() |> JSON.decode!()
end
