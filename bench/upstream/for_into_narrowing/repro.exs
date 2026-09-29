# `for ... into: into`, where `into` may be a list or a bitstring, narrows
# the comprehension body to bitstring(). The stored signature of the
# enclosing function then excludes an argument it accepts at runtime, and
# callers get false type warnings.
#
#     elixir repro.exs                     # the Elixir on PATH
#     /path/to/build/bin/elixir repro.exs  # a given build
#
# Prints compiler diagnostics, the stored (ExCk) signatures, the runtime
# witness and a final
#
#     VERDICT: reproduces | does not reproduce | not applicable (...)

source = ~S"""
defmodule IntoProbe do
  # Accepts any `value`; returns it unchanged.
  def f(flag, value) do
    into = if flag, do: [], else: ""
    _ = for _ <- [1], do: value, into: into
    value
  end

  # The literal form of the same body.
  def literal(flag) do
    into = if flag, do: [], else: ""
    for _ <- [1], do: :ok, into: into
  end

  # A correct call: the list path accepts any element.
  def caller, do: f(true, :ok)
end
"""

info = System.build_info()
IO.puts("Elixir #{System.version()} revision #{info[:revision]} OTP #{info[:otp_release]}")

try do
  Code.compiler_options(ignore_module_conflict: true)

  {binaries, diagnostics} =
    Code.with_diagnostics(fn -> Code.compile_string(source, "into_probe.ex") end)

  for d <- diagnostics do
    IO.puts(
      "diagnostic (#{d.severity}): " <>
        (d.message |> String.replace(~r/\s+/, " ") |> String.trim())
    )
  end

  if diagnostics == [], do: IO.puts("diagnostics: none")

  signatures =
    for {module, binary} <- binaries,
        {:ok, {^module, [{~c"ExCk", chunk}]}} = :beam_lib.chunks(binary, [~c"ExCk"]),
        {_version, %{exports: exports}} = :erlang.binary_to_term(chunk),
        {{name, arity}, %{sig: {:infer, _domain, clauses}}} <- exports,
        into: %{} do
      printed =
        for {args, return} <- clauses do
          {Enum.map(args, &Module.Types.Descr.to_quoted_string/1),
           Module.Types.Descr.to_quoted_string(return)}
        end

      {"#{name}/#{arity}", printed}
    end

  for {function, clauses} <- Enum.sort(signatures), {args, return} <- clauses do
    IO.puts("stored #{function}: (#{Enum.join(args, ", ")}) -> #{return}")
  end

  runtime = IntoProbe.f(true, :ok)
  IO.puts("runtime  f(true, :ok) = #{inspect(runtime)}")
  IO.puts("runtime  literal(true) = #{inspect(IntoProbe.literal(true))}")

  [{[_, second], _}] = signatures["f/2"]

  verdict =
    cond do
      runtime != :ok -> "not applicable (runtime witness changed)"
      second == "bitstring()" -> "reproduces"
      second == "term()" -> "does not reproduce"
      true -> "not applicable (unexpected stored domain #{second})"
    end

  IO.puts("VERDICT: #{verdict}")
rescue
  error ->
    IO.puts(:stderr, "harness failure: #{Exception.message(error)}")
    System.halt(2)
end
