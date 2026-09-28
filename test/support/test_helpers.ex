defmodule SpecLint.TestHelpers do
  @moduledoc false

  alias SpecLint.{Analysis, Beam, Translate, TypeCache}

  @doc false
  @spec beam_path(module()) :: String.t()
  def beam_path(module) do
    case :code.which(module) do
      path when is_list(path) -> List.to_string(path)
    end
  end

  @doc false
  @spec spec_clauses(module(), atom(), arity()) :: [tuple()]
  def spec_clauses(module, name, arity) do
    {:ok, beam} = Beam.read(beam_path(module))
    {:ok, specs} = beam.specs
    {_, clauses} = List.keyfind(specs, {name, arity}, 0)
    clauses
  end

  @doc false
  @spec context(module(), keyword()) :: Translate.context()
  def context(module, opts \\ []) do
    cache = TypeCache.new()
    {:ok, beam} = Beam.read(beam_path(module))
    :ok = TypeCache.put_module(cache, module, beam.md5, beam.types)
    Translate.context(module, cache, opts)
  end

  @doc false
  @spec slice(module(), atom(), arity(), keyword()) :: Translate.slice()
  def slice(module, name, arity, opts \\ []) do
    [clause] = spec_clauses(module, name, arity)
    {:ok, slice} = Translate.slice(clause, context(module, opts))
    slice
  end

  @doc false
  @spec analysed(module(), atom(), arity()) :: Analysis.function_result()
  def analysed(module, name, arity) do
    result = Analysis.module(beam_path(module))
    Enum.find(result.functions, &(&1.mfa == {module, name, arity}))
  end

  @doc false
  @spec project() :: SpecLint.Project.t()
  def project do
    SpecLint.Project.from_ebins([{:spec_lint, Mix.Project.compile_path()}], File.cwd!())
  end

  @doc false
  @spec run!([module()], keyword(), SpecLint.Config.t()) :: SpecLint.Run.t()
  def run!(modules, opts \\ [], config \\ %SpecLint.Config{baseline: "tmp/none.json"}) do
    {:ok, run} = SpecLint.Run.execute(project(), config, [modules: modules] ++ opts)
    run
  end

  @doc false
  @spec issues(SpecLint.Run.t(), mfa()) :: [SpecLint.Issue.t()]
  def issues(run, mfa), do: Enum.filter(run.issues, &(&1.mfa == mfa))

  @doc """
  Rebuilds the BEAM of `module` into `dir` after transforming its chunks.
  """
  @spec rebuild_beam(module(), Path.t(), ([tuple()] -> [tuple()])) :: String.t()
  def rebuild_beam(module, dir, fun) do
    {:ok, binary} = File.read(beam_path(module))
    {:ok, ^module, chunks} = :beam_lib.all_chunks(binary)
    {:ok, rebuilt} = :beam_lib.build_module(fun.(chunks))
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{module}.beam")
    File.write!(path, rebuilt)
    path
  end

  @doc """
  Compiles `source` with `elixirc` in a separate OS process into
  `dir/ebin` and returns the ebin directory. A separate process keeps
  module redefinitions out of the test VM.
  """
  @spec elixirc!(Path.t(), String.t()) :: String.t()
  def elixirc!(dir, source) do
    src = Path.join(dir, "src")
    ebin = Path.join(dir, "ebin")
    File.mkdir_p!(src)
    File.mkdir_p!(ebin)
    file = Path.join(src, "fixture.ex")
    File.write!(file, source)
    elixirc = System.find_executable("elixirc")
    {output, 0} = System.cmd(elixirc, ["-o", ebin, file], stderr_to_stdout: true)
    _ = output
    ebin
  end

  @doc false
  @spec loss_kinds([map()]) :: [atom()]
  def loss_kinds(losses), do: losses |> Enum.map(& &1.kind) |> Enum.uniq() |> Enum.sort()
end
