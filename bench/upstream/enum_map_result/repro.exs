# Enum.map/2 has no parametric signature: its result is dynamic() whatever
# the list and the mapped function, while an equivalent comprehension keeps
# the element shape.
#
#     elixir repro.exs                     # the Elixir on PATH
#     /path/to/build/bin/elixir repro.exs  # a given build
#
# Prints the stored (ExCk) signatures, the runtime witness and a final
#
#     VERDICT: reproduces | does not reproduce | not applicable (...)

source = ~S"""
defmodule EnumMapResult do
  def tags(atoms) when is_list(atoms), do: Enum.map(atoms, fn atom -> {atom, :tag} end)
  def tags_for(atoms) when is_list(atoms), do: for(atom <- atoms, do: {atom, :tag})

  # User-visible consequence: the first is silent, the second warns
  # ("incompatible types given to Kernel.+/2"), although both add 1 to a
  # {atom, :tag} tuple.
  def mapped, do: Enum.map([:a], fn a -> {a, :tag} end) |> hd() |> Kernel.+(1)
  def comprehension, do: (for a <- [:a], do: {a, :tag}) |> hd() |> Kernel.+(1)
end
"""

info = System.build_info()
IO.puts("Elixir #{System.version()} revision #{info[:revision]} OTP #{info[:otp_release]}")

try do
  Code.compiler_options(ignore_module_conflict: true)

  {binaries, diagnostics} =
    Code.with_diagnostics(fn -> Code.compile_string(source, "enum_map_result.ex") end)

  # Which of the two one-line functions above got a type warning?
  names =
    for {text, line} <- Enum.with_index(String.split(source, "\n"), 1),
        [_, name] <- [Regex.run(~r/^\s*def (mapped|comprehension)\b/, text)],
        into: %{},
        do: {line, name}

  warned = for d <- diagnostics, {line, _col} = d.position, name = names[line], do: name
  IO.puts("type warning on mapped/0 (Enum.map): #{"mapped" in warned}")
  IO.puts("type warning on comprehension/0 (for): #{"comprehension" in warned}")

  # The stored signature of Enum.map/2 itself, from the standard library.
  {:ok, {_, [{~c"ExCk", enum_chunk}]}} = :beam_lib.chunks(:code.which(Enum), [~c"ExCk"])
  {_, %{exports: enum_exports}} = :erlang.binary_to_term(enum_chunk)

  with {_, %{sig: {:infer, _, enum_clauses}}} <-
         List.keyfind(Enum.to_list(enum_exports), {:map, 2}, 0) do
    for {args, return} <- enum_clauses do
      IO.puts(
        "stored Enum.map/2: (" <>
          Enum.map_join(args, ", ", &Module.Types.Descr.to_quoted_string/1) <>
          ") -> " <> Module.Types.Descr.to_quoted_string(return)
      )
    end
  end

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

  runtime = EnumMapResult.tags([:a])
  IO.puts("runtime  tags([:a]) = #{inspect(runtime)}")
  IO.puts("runtime  tags_for([:a]) = #{inspect(EnumMapResult.tags_for([:a]))}")

  [via_map] = signatures["tags/1"]
  [via_for] = signatures["tags_for/1"]

  verdict =
    cond do
      runtime != [a: :tag] ->
        "not applicable (runtime witness changed)"

      String.ends_with?(via_map, "-> dynamic()") and
          String.ends_with?(via_for, "-> dynamic(list({term(), :tag}))") ->
        "reproduces"

      String.ends_with?(via_map, "list({term(), :tag}))") ->
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
