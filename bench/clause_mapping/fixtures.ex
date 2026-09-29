# Fixtures for the source-clause mapping experiment (bench/clause_mapping).
# Compiled by recompute.exs into a scratch directory; never part of the
# project build. Clause indexes below are 0-based source clause positions
# within one {name, arity} definition (bodyless heads are not clauses).

defmodule ClauseMappingFixtures.Gen do
  @moduledoc false

  # Injects a catch-all clause quoted with generated: true, like the
  # fallbacks `use` macros append.
  defmacro fallback(name, value) do
    quote generated: true do
      def unquote(name)(_), do: unquote(value)
    end
  end

  # A clause guarded by is_integer/1 or is_list/1, quoted with
  # generated: true: the compiler reports no redundant clause for it.
  defmacro guarded_fallback(name, guard, value) do
    quote generated: true do
      def unquote(name)(x) when unquote(guard)(x), do: unquote(value)
    end
  end
end

defmodule ClauseMappingFixtures do
  @moduledoc false
  require ClauseMappingFixtures.Gen

  # 1. Merged clauses with equal returns (arity 1: any two clauses with a
  #    term-equal return merge by group_clauses_by_return).
  @spec merged_equal(term()) :: term()
  def merged_equal(:a), do: :x
  def merged_equal(:b), do: :x
  def merged_equal(:c), do: :y

  # 1b. Arity 2: clauses with equal returns that differ in one position
  #     merge; a third that differs in two positions from the merged clause
  #     does not.
  @spec merged_chain(term(), term()) :: term()
  def merged_chain(:a, :x), do: :same
  def merged_chain(:b, :x), do: :same
  def merged_chain(:b, :y), do: :same

  # 2. A raising clause between two live ones (precise head, return none()).
  @spec raising_between(term()) :: term()
  def raising_between(:a), do: :first
  def raising_between(:b), do: raise(ArgumentError, "b")
  def raising_between(:c), do: :third

  # 2b. Same, but the live returns are equal, so the survivors also merge.
  @spec raising_merged(term()) :: term()
  def raising_merged(:a), do: :live
  def raising_merged(:b), do: raise(ArgumentError, "b")
  def raising_merged(:c), do: :live

  # 3. Guards that narrow domains. is_integer/is_binary are precise and are
  #    subtracted from later heads; `x > 10` is not, so the imprecise
  #    first clause is not subtracted.
  @spec guarded(term()) :: term()
  def guarded(x) when is_integer(x), do: {:int, x}
  def guarded(x) when is_binary(x), do: {:bin, x}
  def guarded(x) when is_integer(x) or is_float(x), do: {:num, x}
  def guarded(_), do: :other

  # (Clauses 0 and 1 both have domain integer() and merge in add_inferred.)
  @spec guarded_imprecise(term()) :: term()
  def guarded_imprecise(x) when is_integer(x) and x > 10, do: :big
  def guarded_imprecise(x) when is_integer(x), do: :small
  def guarded_imprecise(x) when is_atom(x), do: :big

  # 4. Defaults producing two arities: with_default/1 is a generated clause
  #    whose body is {:super, _, [a, :dflt]}.
  @spec with_default(term(), term()) :: term()
  def with_default(a, b \\ :dflt)
  def with_default(a, :dflt), do: {:default, a}
  def with_default(a, b) when is_integer(b), do: {:int, a, b}
  def with_default(_a, _b), do: :other

  # 5. A macro: no checker signature is stored for macros.
  defmacro mac(:a), do: :a
  defmacro mac(x), do: x

  # 6. generated: true clause appended after user clauses; it returns the
  #    same as clause 1, so they merge.
  @spec gen(term()) :: term()
  def gen(:a), do: :a_result
  def gen(:b), do: :fallback
  ClauseMappingFixtures.Gen.fallback(:gen, :fallback)

  # 7. Clauses shadowed by an earlier catch-all: distinct and equal returns.
  @spec shadowed(term()) :: term()
  def shadowed(_), do: :any
  def shadowed(:a), do: :never

  @spec shadowed_same(term()) :: term()
  def shadowed_same(_), do: :any
  def shadowed_same(:a), do: :any

  # 8. More than 16 clauses (the application cutoff is @max_clauses 16).
  #    Atom literals are precise and distinct: 20 stored clauses.
  @spec many_atoms(term()) :: term()
  for i <- 0..19 do
    def many_atoms(unquote(:"a#{i}")), do: unquote(:"r#{i}")
  end

  # Integer literals type as integer(): identical domains merge in
  # add_inferred into a single stored clause.
  @spec many_ints(term()) :: term()
  for i <- 0..19 do
    def many_ints(unquote(i)), do: unquote(:"r#{i}")
  end

  # 20 clauses, three of which raise: 17 stored clauses.
  @spec many_raising(term()) :: term()
  for i <- 0..19 do
    if i in [3, 9, 15] do
      def many_raising(unquote(:"a#{i}")), do: raise(ArgumentError, "no")
    else
      def many_raising(unquote(:"a#{i}")), do: unquote(:"r#{i}")
    end
  end

  # 9. Overloads with overlapping domains: the imprecise first clause is
  #    not subtracted, so both clauses have domain integer() and merge in
  #    add_inferred (returns unioned).
  @spec overlap(term()) :: term()
  def overlap(x) when is_integer(x) and x > 0, do: :pos
  def overlap(x) when is_integer(x), do: :nonpos

  @spec overlap2(term(), term()) :: term()
  def overlap2(x, y) when is_integer(x) and x > 0, do: {:a, y}
  def overlap2(x, y) when is_atom(y), do: {:b, x}

  # 10. A clause whose return is none() through a local helper.
  @spec via_helper(term()) :: term()
  def via_helper(:ok), do: :fine
  def via_helper(:bad), do: fail(:bad)
  def via_helper(:other), do: :other

  defp fail(reason), do: raise(ArgumentError, inspect(reason))

  # 11. Extra controls.
  # A precise raising clause whose domain overlaps nothing that survives.
  @spec dup_raise(term()) :: term()
  def dup_raise(x) when is_atom(x), do: raise(ArgumentError, "no")
  def dup_raise(x), do: x

  # Every clause raises: nothing is dropped (non_empty? is false), and the
  # two none() returns are term-equal, so the clauses merge by return.
  @spec all_raise(term()) :: term()
  def all_raise(:a), do: raise(ArgumentError, "a")
  def all_raise(:b), do: raise(ArgumentError, "b")

  # The body refines the head variable (x + 1 needs a number).
  @spec refined(term()) :: term()
  def refined(x) when is_integer(x) or is_atom(x), do: x + 1
  def refined(y), do: y

  # A single clause.
  @spec single(term()) :: term()
  def single(x), do: x
end

# Counterexamples of the Milestone 4 review (README.md, R1-R3), one module
# each, because the subpatterns leak (E1) depends on the other definitions
# of the module.

defmodule ClauseMappingFixtures.Adv3 do
  @moduledoc false

  # R1: clause 1 is redundant (the compiler warns); its head is what is left
  # after subtracting clause 0, outside the head it has without previous
  # clauses.
  @spec redundant(term()) :: term()
  def redundant(x) when is_integer(x) or is_atom(x), do: :num_or_atom
  def redundant(x) when is_integer(x), do: :never
  def redundant(_), do: :rest
end

defmodule ClauseMappingFixtures.Adv4 do
  @moduledoc false
  require ClauseMappingFixtures.Gen

  # R1 without a warning: the redundant clause is quoted with
  # generated: true, as a `use` macro would inject it.
  @spec gen_red(term()) :: term()
  def gen_red(x) when is_integer(x) or is_atom(x), do: :user
  ClauseMappingFixtures.Gen.guarded_fallback(:gen_red, :is_integer, :gen)
  def gen_red(_), do: :rest
end

defmodule ClauseMappingFixtures.Adv6 do
  @moduledoc false
  require ClauseMappingFixtures.Gen

  # R2: the list pattern of a/1 leaks a subpattern (E1), so the compiler
  # keeps b/1's generated clause 1 (a repeated guard, no warning) with the
  # head list() while the fresh recomputation types it as not list().
  @spec a(term()) :: term()
  def a([x | _]), do: x

  @spec b(term()) :: term()
  def b(y) when is_list(y), do: :l
  ClauseMappingFixtures.Gen.guarded_fallback(:b, :is_list, :m)
  def b(z) when not is_list(z), do: :r
end

defmodule ClauseMappingFixtures.Adv7 do
  @moduledoc false

  # R3: as many stored as source clauses, so I1 and I2 force the identity,
  # although clause 1 is redundant and no typed solve finds a solution.
  @spec ident(term()) :: term()
  def ident(x) when is_integer(x), do: :int
  def ident(x) when is_integer(x), do: :never
  def ident(:z), do: :zed
end

defmodule ClauseMappingFixtures.Expected do
  @moduledoc false

  # Hand-written from the source above and the pipeline in README.md
  # ("Pipeline"), before running recompute.exs. For each {name, arity}:
  #
  #   {:stored, [members_of_stored_clause_0, members_1, ...], dropped}
  #   {:super, stored_count_note} - the generated default clause (one source
  #                                 clause; every stored clause maps to it)
  #   :not_stored                 - no checker signature (macros)
  #
  # members are 0-based source clause indexes; dropped lists the source
  # clauses that no stored clause contains.
  @spec adversarial() :: %{optional(module()) => %{optional({atom(), arity()}) => term()}}
  def adversarial do
    %{
      ClauseMappingFixtures.Adv3 => %{{:redundant, 1} => {:stored, [[0], [1, 2]], []}},
      ClauseMappingFixtures.Adv4 => %{{:gen_red, 1} => {:stored, [[0], [1, 2]], []}},
      ClauseMappingFixtures.Adv6 => %{
        {:a, 1} => {:stored, [[0]], []},
        {:b, 1} => {:stored, [[0, 1], [2]], []}
      },
      ClauseMappingFixtures.Adv7 => %{{:ident, 1} => {:stored, [[0], [1], [2]], []}}
    }
  end

  @spec expected() :: %{optional({atom(), arity()}) => term()}
  def expected do
    %{
      {:merged_equal, 1} => {:stored, [[0, 1], [2]], []},
      {:merged_chain, 2} => {:stored, [[0, 1], [2]], []},
      {:raising_between, 1} => {:stored, [[0], [2]], [1]},
      {:raising_merged, 1} => {:stored, [[0, 2]], [1]},
      {:guarded, 1} => {:stored, [[0], [1], [2], [3]], []},
      # Corrected after the first run: the hand expectation was
      # {:stored, [[0, 2], [1]], []}, which forgot that clauses 0 and 1 have
      # term-equal domains (integer(); clause 0 is imprecise, so it is not
      # subtracted from clause 1) and merge in add_inferred before
      # group_clauses_by_return sees them. The merged return :big or :small
      # then differs from clause 2's :big. README.md, "Fixture results".
      {:guarded_imprecise, 1} => {:stored, [[0, 1], [2]], []},
      {:with_default, 2} => {:stored, [[0], [1], [2]], []},
      {:with_default, 1} => {:super, :one_source_clause},
      {:mac, 1} => :not_stored,
      {:gen, 1} => {:stored, [[0], [1, 2]], []},
      {:shadowed, 1} => {:stored, [[0], [1]], []},
      {:shadowed_same, 1} => {:stored, [[0, 1]], []},
      {:many_atoms, 1} => {:stored, Enum.map(0..19, &[&1]), []},
      {:many_ints, 1} => {:stored, [Enum.to_list(0..19)], []},
      {:many_raising, 1} => {:stored, for(i <- 0..19, i not in [3, 9, 15], do: [i]), [3, 9, 15]},
      {:overlap, 1} => {:stored, [[0, 1]], []},
      {:overlap2, 2} => {:stored, [[0], [1]], []},
      {:via_helper, 1} => {:stored, [[0], [2]], [1]},
      {:dup_raise, 1} => {:stored, [[1]], [0]},
      {:all_raise, 1} => {:stored, [[0, 1]], []},
      {:refined, 1} => {:stored, [[0], [1]], []},
      {:single, 1} => {:stored, [[0]], []}
    }
  end
end
