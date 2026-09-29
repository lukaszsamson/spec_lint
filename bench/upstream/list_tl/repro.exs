# Module.Types.Descr.list_tl/1 excludes an achievable tail.
#
#     elixir repro.exs                     # the Elixir on PATH
#     /path/to/build/bin/elixir repro.exs  # a given build
#
# Pure type-algebra probe of an internal module (no compilation involved).
# Prints the observations and a final
#
#     VERDICT: reproduces | does not reproduce | not applicable (...)
#
# The lists [:x, :y] and [:x, :y, :y, :z] belong to
# `non_empty_list(atom()) and not non_empty_list(:y)` (non-empty lists of
# atoms that are not made only of :y). Their tails, [:y] and [:y, :y, :z],
# are lists of atoms, and [:y] is a non-empty list of :y. list_tl/1 must
# therefore not claim that [:y] is impossible as a tail.

alias Module.Types.Descr

info = System.build_info()
IO.puts("Elixir #{System.version()} revision #{info[:revision]} OTP #{info[:otp_release]}")

try do
  Code.ensure_loaded(Descr)

  if not function_exported?(Descr, :list_tl, 1) do
    IO.puts("VERDICT: not applicable (Module.Types.Descr.list_tl/1 does not exist)")
    System.halt(0)
  end

  t = Descr.opt_difference(Descr.list(Descr.atom()), Descr.list(Descr.atom([:y])))
  {:ok, tail} = Descr.list_tl(t)
  y_lists = Descr.non_empty_list(Descr.atom([:y]))

  subtype = Descr.subtype?(y_lists, tail)
  disjoint = Descr.disjoint?(y_lists, tail)

  IO.puts("t            = #{Descr.to_quoted_string(t)}")
  IO.puts("list_tl(t)   = #{Descr.to_quoted_string(tail)}")
  IO.puts("subtype?(non_empty_list(:y), list_tl(t))  = #{subtype}")
  IO.puts("disjoint?(non_empty_list(:y), list_tl(t)) = #{disjoint}")

  # Control: t itself correctly excludes non_empty_list(:y).
  control = Descr.disjoint?(y_lists, t)
  IO.puts("disjoint?(non_empty_list(:y), t)          = #{control}  (correct: true)")

  # The correct tail is list(atom()) with no exclusion.
  IO.puts(
    "equal?(list_tl(t), list(atom()))          = #{Descr.equal?(tail, Descr.list(Descr.atom()))}"
  )

  verdict =
    cond do
      not control -> "not applicable (control changed)"
      disjoint -> "reproduces"
      true -> "does not reproduce"
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
