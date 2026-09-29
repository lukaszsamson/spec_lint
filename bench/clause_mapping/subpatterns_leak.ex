# Minimal reproducer (README.md, E1): the stored signature of b/1 depends on
# an unrelated earlier definition. Module.Types does not reset
# context.subpatterns between clauses or definitions (types.ex:708-710 on
# c24c235 and 648b2a9), so the {:list, version} entry a/1's list pattern
# leaves behind makes the guard is_list(y) of b/1 (same variable version)
# imprecise (pattern.ex:990, 1226-1229): clause 0 is not subtracted from
# clause 1, whose stored domain becomes term() instead of not list.
#
#   elixirc -o ebin bench/clause_mapping/subpatterns_leak.ex
#
# c24c235 and 648b2a9 both store:
#   LeakWith.b/1:    list -> integer() ; term() -> dynamic()
#   LeakWithout.b/1: list -> integer() ; not list -> dynamic(not list)
# Sound (a wider domain), but order-dependent: head domains cannot be
# recomputed from a clause's own head alone.

defmodule LeakWith do
  @moduledoc false
  @spec a(term()) :: term()
  def a([x | _]), do: x
  @spec b(term()) :: term()
  def b(y) when is_list(y), do: 1
  def b(z), do: z
end

defmodule LeakWithout do
  @moduledoc false
  @spec b(term()) :: term()
  def b(y) when is_list(y), do: 1
  def b(z), do: z
end
