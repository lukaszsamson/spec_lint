# Feature request, not a bug: the checker chunk (ExCk) stores the inferred
# signature of a function without any link from a stored clause to the
# source clause(s) it came from, and without a per-clause reachability
# verdict.
#
#     elixir repro.exs                     # the Elixir on PATH
#     /path/to/build/bin/elixir repro.exs  # a given build
#
# Compiles three functions, then prints for each the number of source
# clauses (from the debug info), the number of stored clauses, the keys the
# ExCk chunk offers, and the compiler diagnostics. A final
#
#     VERDICT: reproduces | does not reproduce | not applicable (...)
#
# where "reproduces" means the gap exists: the chunk carries nothing but
# `sig` per function and source and stored clause counts differ.

source = ~S"""
defmodule ClauseGap do
  # Two source clauses with the same return merge into one stored clause.
  def merged(:a), do: 1
  def merged(:b), do: 1
  def merged(:c), do: :x

  # A clause that always raises is dropped from the stored signature on 1.21
  # (kept as `-> none()` on 1.20).
  def dropped(:a), do: :ok
  def dropped(:b), do: raise("boom")

  # Clause 1 is redundant: the compiler warns, the chunk says nothing.
  def redundant(x) when is_atom(x), do: 1
  def redundant(:a), do: 2
  def redundant(_), do: 3
end
"""

info = System.build_info()
IO.puts("Elixir #{System.version()} revision #{info[:revision]} OTP #{info[:otp_release]}")

try do
  Code.compiler_options(ignore_module_conflict: true, debug_info: true)

  {[{module, binary}], diagnostics} =
    Code.with_diagnostics(fn -> Code.compile_string(source, "clause_gap.ex") end)

  for d <- diagnostics do
    message = d.message |> String.replace(~r/\s+/, " ") |> String.trim()
    IO.puts("diagnostic (line #{inspect(d.position)}): #{message}")
  end

  {:ok, {_, [{~c"ExCk", chunk}]}} = :beam_lib.chunks(binary, [~c"ExCk"])
  {version, %{exports: exports} = checker} = :erlang.binary_to_term(chunk)
  IO.puts("checker chunk version: #{inspect(version)}, keys: #{inspect(Map.keys(checker))}")

  {:ok, {_, [{~c"Dbgi", dbgi}]}} = :beam_lib.chunks(binary, [~c"Dbgi"])
  {:debug_info_v1, backend, data} = :erlang.binary_to_term(dbgi)
  {:ok, debug} = backend.debug_info(:elixir_v1, module, data, [])

  source_counts =
    for {{name, arity}, _kind, _meta, clauses} <- debug.definitions, into: %{} do
      {{name, arity}, length(clauses)}
    end

  rows =
    for {{name, arity}, entry} <- Enum.sort(exports),
        %{sig: {:infer, _domain, clauses}} = entry do
      IO.puts(
        "#{name}/#{arity}: #{source_counts[{name, arity}]} source clauses, #{length(clauses)} stored, export keys #{inspect(Map.keys(entry))}"
      )

      for {args, return} <- clauses do
        IO.puts(
          "    (" <>
            Enum.map_join(args, ", ", &Module.Types.Descr.to_quoted_string/1) <>
            ") -> " <> Module.Types.Descr.to_quoted_string(return)
        )
      end

      {Map.keys(entry), source_counts[{name, arity}], length(clauses)}
    end

  verdict =
    cond do
      rows == [] -> "not applicable (no inferred signature found)"
      Enum.any?(rows, fn {keys, _, _} -> keys != [:sig] end) -> "does not reproduce"
      Enum.any?(rows, fn {_, source, stored} -> source != stored end) -> "reproduces"
      true -> "not applicable (source and stored clause counts all agree)"
    end

  IO.puts("VERDICT: #{verdict}")
rescue
  error ->
    IO.puts(:stderr, "harness failure: #{Exception.message(error)}")
    System.halt(2)
end
