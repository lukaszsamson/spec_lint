# A closed map that is equal to map() prints as an 11-domain literal.
#
#     elixir repro.exs                     # the Elixir on PATH
#     /path/to/build/bin/elixir repro.exs  # a given build
#
# Prints the observations and a final
#
#     VERDICT: reproduces | does not reproduce | not applicable (...)

import Module.Types.Descr

info = System.build_info()
IO.puts("Elixir #{System.version()} revision #{info[:revision]} OTP #{info[:otp_release]}")

try do
  # One domain per key kind, every value term(), no required keys: the
  # shape a translated %{optional(any()) => any()} spec takes.
  kinds = [
    :atom,
    :integer,
    :float,
    :binary,
    :bitstring_no_binary,
    :pid,
    :port,
    :reference,
    :tuple,
    :map,
    :list,
    :fun
  ]

  m = closed_map(for k <- kinds, do: {[k], term()})
  equal = equal?(m, open_map())
  printed = to_quoted_string(m)

  IO.puts("equal?(m, open_map()) = #{equal}")
  IO.puts("to_quoted_string(open_map()) = #{to_quoted_string(open_map())}")
  IO.puts("to_quoted_string(m) =")
  IO.puts(printed)

  verdict =
    cond do
      not equal -> "not applicable (the map is not equal to map())"
      printed == "map()" -> "does not reproduce"
      true -> "reproduces"
    end

  IO.puts("VERDICT: #{verdict}")
rescue
  error in [UndefinedFunctionError, FunctionClauseError, ArgumentError, MatchError] ->
    IO.puts("not applicable: #{Exception.message(error) |> String.split("\n") |> hd()}")
    IO.puts("VERDICT: not applicable (Module.Types.Descr API differs)")

  error ->
    IO.puts(:stderr, "harness failure: #{Exception.message(error)}")
    System.halt(2)
end
