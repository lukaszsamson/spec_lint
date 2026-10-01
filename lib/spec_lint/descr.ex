defmodule SpecLint.Descr do
  @moduledoc false
  # The few `Module.Types.Descr` entry points whose names differ between
  # Elixir 1.20 and 1.21. Everything else is imported from the compiler.

  alias Module.Types.Descr

  @spec union(term(), term()) :: term()
  @spec intersection(term(), term()) :: term()
  @spec difference(term(), term()) :: term()
  @spec field(term(), boolean()) :: term()

  if Code.ensure_loaded?(Descr) and function_exported?(Descr, :opt_union, 2) do
    def union(left, right), do: Descr.opt_union(left, right)
    def intersection(left, right), do: Descr.opt_intersection(left, right)
    def difference(left, right), do: Descr.opt_difference(left, right)
    def field(value, optional?), do: {value, optional?}
  else
    def union(left, right), do: Descr.union(left, right)
    def intersection(left, right), do: Descr.intersection(left, right)
    def difference(left, right), do: Descr.difference(left, right)
    def field(value, true), do: Descr.if_set(value)
    def field(value, false), do: value
  end
end
