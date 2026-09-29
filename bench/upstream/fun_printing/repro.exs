# The type printer prints fun(2) and (none(), none() -> term()) identically
# although the two types are not equal.
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
  any_binary_fun = fun(2)
  bottom_arrow = fun([none(), none()], term())

  a = to_quoted_string(any_binary_fun)
  b = to_quoted_string(bottom_arrow)
  equal = equal?(any_binary_fun, bottom_arrow)

  IO.puts("to_quoted_string(fun(2))                        = #{a}")
  IO.puts("to_quoted_string(fun([none(), none()], term())) = #{b}")
  IO.puts("equal?(fun(2), fun([none(), none()], term()))   = #{equal}")

  # Which direction fails. Under the usual semantics an arrow with a none()
  # domain is a supertype of every function of that arity, so either the two
  # types are equal or the printer should tell them apart. Here the arrow is
  # a subtype of fun(2) but fun(2) is not a subtype of the arrow.
  IO.puts(
    "subtype?(fun(2), arrow)                         = #{subtype?(any_binary_fun, bottom_arrow)}"
  )

  IO.puts(
    "subtype?(arrow, fun(2))                         = #{subtype?(bottom_arrow, any_binary_fun)}"
  )

  IO.puts("to_quoted_string(fun(1))                        = #{to_quoted_string(fun(1))}")
  IO.puts("to_quoted_string(fun(0))                        = #{to_quoted_string(fun(0))}")

  verdict =
    cond do
      a == b and not equal -> "reproduces"
      a != b -> "does not reproduce"
      true -> "not applicable (the two types are equal)"
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
