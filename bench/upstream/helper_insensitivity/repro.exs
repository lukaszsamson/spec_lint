# Local helper indirection loses a literal return shape that is preserved
# when the helper is inlined.
#
#     elixir repro.exs                     # the Elixir on PATH
#     /path/to/build/bin/elixir repro.exs  # a given build
#
# Standalone: compiles the module below in memory, prints the inferred
# signature the compiler stores in the module's checker chunk (ExCk), runs
# the runtime witness, and prints a final line
#
#     VERDICT: reproduces | does not reproduce | not applicable (...)
#
# Exit status 0 when a verdict was printed, 2 when the script itself failed.

source = ~S"""
defmodule HelperInsensitivity do
  # Returns its second argument unless trapped, like Decimal's handle_error/4.
  defp handle_error(signal, result) do
    if Process.get({__MODULE__, :trap, signal}), do: raise(ArgumentError, "#{signal}")
    result
  end

  def sign(:nan), do: handle_error(:invalid_operation, {:error, :nan})
  def sign(n) when is_integer(n) and n < 0, do: :negative
  def sign(n) when is_integer(n) and n > 0, do: :positive
  def sign(n) when is_integer(n), do: :zero

  # The same clauses with the helper call written out by hand.
  def sign_inline(:nan), do: {:error, :nan}
  def sign_inline(n) when is_integer(n) and n < 0, do: :negative
  def sign_inline(n) when is_integer(n) and n > 0, do: :positive
  def sign_inline(n) when is_integer(n), do: :zero

  # User-visible consequence: the first is silent, the second warns
  # ("incompatible types given to Kernel.+/2"), although both add 1 to
  # {:error, :nan}.
  def with_helper, do: handle_error(:invalid_operation, {:error, :nan}) + 1
  def inlined, do: (r = {:error, :nan}; if(Process.get({__MODULE__, :trap, :invalid_operation}), do: raise(ArgumentError, "invalid_operation")); r + 1)
end
"""

info = System.build_info()
IO.puts("Elixir #{System.version()} revision #{info[:revision]} OTP #{info[:otp_release]}")

try do
  Code.compiler_options(ignore_module_conflict: true)

  {binaries, diagnostics} =
    Code.with_diagnostics(fn -> Code.compile_string(source, "helper_insensitivity.ex") end)

  # Which of the two one-line functions above got a type warning?
  names =
    for {text, line} <- Enum.with_index(String.split(source, "\n"), 1),
        [_, name] <- [Regex.run(~r/^\s*def (with_helper|inlined)\b/, text)],
        into: %{},
        do: {line, name}

  warned = for d <- diagnostics, {line, _col} = d.position, name = names[line], do: name
  IO.puts("type warning on with_helper/0 (helper call): #{"with_helper" in warned}")
  IO.puts("type warning on inlined/0 (helper body written out): #{"inlined" in warned}")

  signatures =
    for {module, binary} <- binaries,
        {:ok, {^module, [{~c"ExCk", chunk}]}} = :beam_lib.chunks(binary, [~c"ExCk"]),
        {_version, %{exports: exports}} = :erlang.binary_to_term(chunk),
        {{name, arity}, %{sig: {:infer, _domain, clauses}}} <- exports,
        into: %{} do
      printed =
        for {args, return} <- clauses do
          "(" <>
            Enum.map_join(args, ", ", &Module.Types.Descr.to_quoted_string/1) <>
            ") -> " <> Module.Types.Descr.to_quoted_string(return)
        end

      {"#{name}/#{arity}", printed}
    end

  for {function, clauses} <- Enum.sort(signatures), clause <- clauses do
    IO.puts("stored #{function}: #{clause}")
  end

  runtime = HelperInsensitivity.sign(:nan)
  IO.puts("runtime  sign(:nan) = #{inspect(runtime)}")
  IO.puts("runtime  sign_inline(:nan) = #{inspect(HelperInsensitivity.sign_inline(:nan))}")

  [via_helper | _] = signatures["sign/1"]
  [inlined | _] = signatures["sign_inline/1"]

  verdict =
    cond do
      runtime != {:error, :nan} ->
        "not applicable (runtime witness changed)"

      via_helper == "(:nan) -> dynamic()" and inlined == "(:nan) -> {:error, :nan}" ->
        "reproduces"

      via_helper == inlined ->
        "does not reproduce"

      true ->
        "not applicable (unexpected stored signatures)"
    end

  IO.puts("VERDICT: #{verdict}")
rescue
  error ->
    IO.puts(:stderr, "harness failure: #{Exception.message(error)}")
    System.halt(2)
end
