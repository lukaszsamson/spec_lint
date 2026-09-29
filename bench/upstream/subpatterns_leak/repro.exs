# The stored signature of a function depends on an unrelated earlier
# definition: Module.Types does not reset `context.subpatterns` between
# definitions, so a list pattern in a/1 makes the `is_list(y)` guard of b/1
# (same variable version) imprecise.
#
#     elixir repro.exs                     # the Elixir on PATH
#     /path/to/build/bin/elixir repro.exs  # a given build
#
# LeakWith.b/1 and LeakWithout.b/1 have identical source; only LeakWith
# also defines a/1 (a list pattern) before it. Prints the stored (ExCk)
# signatures and a final
#
#     VERDICT: reproduces | does not reproduce | not applicable (...)
#
# The wider domain is sound; the point is that it is order-dependent.

source = ~S"""
defmodule LeakWith do
  def a([x | _]), do: x
  def b(y) when is_list(y), do: 1
  def b(z), do: z
end

defmodule LeakWithout do
  def b(y) when is_list(y), do: 1
  def b(z), do: z
end
"""

info = System.build_info()
IO.puts("Elixir #{System.version()} revision #{info[:revision]} OTP #{info[:otp_release]}")

try do
  Code.compiler_options(ignore_module_conflict: true)
  binaries = Code.compile_string(source, "subpatterns_leak.ex")

  signatures =
    for {module, binary} <- binaries,
        {:ok, {^module, [{~c"ExCk", chunk}]}} = :beam_lib.chunks(binary, [~c"ExCk"]),
        {_version, %{exports: exports}} = :erlang.binary_to_term(chunk),
        {{name, arity}, %{sig: {:infer, _domain, clauses}}} <- exports,
        into: %{} do
      printed =
        for {args, return} <- clauses do
          Enum.map_join(args, ", ", &Module.Types.Descr.to_quoted_string/1) <>
            " -> " <> Module.Types.Descr.to_quoted_string(return)
        end

      {"#{inspect(module)}.#{name}/#{arity}", printed}
    end

  for {function, clauses} <- Enum.sort(signatures), clause <- clauses do
    IO.puts("stored #{function}: #{clause}")
  end

  with_leak = signatures["LeakWith.b/1"]
  without_leak = signatures["LeakWithout.b/1"]

  verdict =
    cond do
      with_leak == without_leak -> "does not reproduce"
      length(with_leak) == length(without_leak) -> "reproduces"
      true -> "not applicable (different clause structure)"
    end

  IO.puts("VERDICT: #{verdict}")
rescue
  error ->
    IO.puts(:stderr, "harness failure: #{Exception.message(error)}")
    System.halt(2)
end
