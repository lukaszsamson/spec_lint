defmodule SpecLint.ClauseMappingFixtures.Gen do
  @moduledoc false

  # A clause quoted with generated: true, like the fallbacks `use` macros
  # append; the compiler reports no redundant-clause warning for it.
  defmacro generated_clause(name, guard_var, value) do
    quote generated: true do
      def unquote(name)(unquote(guard_var)) when is_integer(unquote(guard_var)),
        do: unquote(value)
    end
  end
end

defmodule SpecLint.ClauseMappingFixtures do
  @moduledoc false
  # Source-clause mapping (Milestone 4, SpecLint.ClauseMapping). The
  # expected mapping of every definition is in
  # test/spec_lint/clause_mapping_test.exs; the shapes are those of
  # bench/clause_mapping/fixtures.ex, where the instrumented replay of the
  # compiler (c24c235) confirmed them.
  require SpecLint.ClauseMappingFixtures.Gen, as: Gen

  # One source clause.
  @spec single(term()) :: term()
  def single(x), do: x

  # Defaults: with_default/2 has three source and three stored clauses;
  # with_default/1 is the generated {:super, ...} clause.
  @spec with_default(term(), term()) :: term()
  def with_default(a, b \\ :dflt)
  def with_default(a, :dflt), do: {:default, a}
  def with_default(a, b) when is_integer(b), do: {:int, a, b}
  def with_default(_a, _b), do: :other

  # Distinct precise guards: as many stored as source clauses.
  @spec guarded(term()) :: {atom(), number() | binary()} | :other
  def guarded(x) when is_integer(x), do: {:int, x}
  def guarded(x) when is_binary(x), do: {:bin, x}
  def guarded(x) when is_integer(x) or is_float(x), do: {:num, x}
  def guarded(_), do: :other

  # Equal returns merge (group_clauses_by_return): 3 source, 2 stored.
  @spec merged(:a | :b | :c) :: :x | :y
  def merged(:a), do: :x
  def merged(:b), do: :x
  def merged(:c), do: :y

  # A raising clause: dropped by 1.21 (2 stored), stored as `-> none()` by
  # 1.20.4 (3 stored).
  @spec raising(:a | :b | :c) :: :first | :third
  def raising(:a), do: :first
  def raising(:b), do: raise(ArgumentError, "b")
  def raising(:c), do: :third

  # Every clause raises: nothing is dropped, and the equal none() returns
  # merge: 2 source, 1 stored.
  @spec all_raise(:a | :b) :: no_return()
  def all_raise(:a), do: raise(ArgumentError, "a")
  def all_raise(:b), do: raise(ArgumentError, "b")

  # A redundant clause (review counterexample adv7, quoted with
  # generated: true here so the test build stays free of warnings; the
  # checker takes the same path): one stored clause per source clause.
  @spec redundant(integer() | :z) :: :int | :never | :zed
  def redundant(x) when is_integer(x), do: :int
  Gen.generated_clause(:redundant, x, :never)
  def redundant(:z), do: :zed

  # A redundant clause quoted with generated: true (review counterexample
  # adv4): no warning; the head types merge.
  @spec gen_red(term()) :: :user | :gen | :rest
  def gen_red(x) when is_integer(x) or is_atom(x), do: :user
  Gen.generated_clause(:gen_red, x, :gen)
  def gen_red(_), do: :rest

  # More clauses than the application cutoff (16): distinct atom literals.
  @spec many(atom()) :: atom()
  for i <- 0..19 do
    def many(unquote(:"a#{i}")), do: unquote(:"r#{i}")
  end

  # Clause conflicts (SL001) in each class. identity_conflict/1: stored
  # clause 1 is source clause 1. ambiguous_conflict/1: its first two
  # clauses merge, so stored clause 1 is source clause 2, which the stored
  # signature alone does not show.
  @spec identity_conflict(:a | :b) :: atom()
  def identity_conflict(:a), do: :x
  def identity_conflict(:b), do: "b"

  @spec ambiguous_conflict(:a | :b | :c) :: atom()
  def ambiguous_conflict(:a), do: :x
  def ambiguous_conflict(:b), do: :x
  def ambiguous_conflict(:c), do: "c"
end
