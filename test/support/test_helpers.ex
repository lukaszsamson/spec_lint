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
  @spec loss_kinds([map()]) :: [atom()]
  def loss_kinds(losses), do: losses |> Enum.map(& &1.kind) |> Enum.uniq() |> Enum.sort()
end
