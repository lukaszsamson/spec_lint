defmodule SpecLint.Descr do
  @moduledoc false
  # The few `Module.Types.Descr` entry points that differ between Elixir
  # 1.18, 1.19, 1.20 and 1.21. Everything else is imported from the
  # compiler.

  alias Module.Types.Descr

  @spec union(term(), term()) :: term()
  @spec intersection(term(), term()) :: term()
  @spec difference(term(), term()) :: term()
  @spec field(term(), boolean()) :: term()
  @spec upper_bound(term()) :: term()
  @spec map_fetch_key(term(), atom()) :: {boolean(), term()} | atom()
  @spec bitstring() :: term()
  @spec bitstring_no_binary() :: term()
  @spec fun_type([term()], term(), boolean()) :: {term(), boolean()}
  @spec fun_of_arity(arity()) :: term()

  # Elixir 1.21: set operations are `opt_*`, map pairs carry the optional flag.
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

  # Elixir 1.18 and 1.19: the gradual upper bound is the `dynamic` part
  # (which contains the static part), the map key fetch is `map_fetch/2`,
  # and the lattice has one binary kind covering every bitstring.
  if Code.ensure_loaded?(Descr) and function_exported?(Descr, :upper_bound, 1) do
    defdelegate upper_bound(descr), to: Descr
    defdelegate map_fetch_key(descr, key), to: Descr
    defdelegate bitstring(), to: Descr
    defdelegate bitstring_no_binary(), to: Descr
  else
    def upper_bound(%{dynamic: dynamic}), do: dynamic
    def upper_bound(descr), do: descr
    def map_fetch_key(descr, key), do: Descr.map_fetch(descr, key)
    def bitstring, do: Descr.binary()
    def bitstring_no_binary, do: Descr.none()
  end

  # Elixir 1.18 has no function types beyond `fun()`.
  if Code.ensure_loaded?(Descr) and function_exported?(Descr, :fun, 2) do
    def fun_type(args, return, exact?), do: {Descr.fun(args, return), exact?}
    def fun_of_arity(arity), do: Descr.fun(arity)
  else
    def fun_type(_args, _return, _exact?), do: {Descr.fun(), false}
    def fun_of_arity(_arity), do: Descr.fun()
  end
end
