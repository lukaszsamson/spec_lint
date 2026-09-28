defmodule SpecLint.Fixtures.Remote do
  @moduledoc false

  @typedoc "Parameterised type whose argument must be resolved in the caller."
  @type wrap(x) :: {x}

  @typedoc "Same name as a caller-local type; must not capture caller arguments."
  @type local :: integer()

  @opaque secret :: {integer()}

  @spec make_secret(integer()) :: secret()
  def make_secret(n), do: {n}
end

defmodule SpecLint.Fixtures.Types do
  @moduledoc false

  @type local :: atom()
  @type tree :: {:leaf, integer()} | {:node, tree(), tree()}
  @opaque own :: {atom()}

  @spec literal_atom(:a) :: :a
  def literal_atom(x), do: x

  @spec refined(pos_integer(), non_neg_integer(), 1..10, -1, byte()) :: char()
  def refined(_, _, _, _, _), do: 0

  @spec sized(<<_::8>>, <<_::_*8>>, <<_::_*1>>, nonempty_binary()) :: <<_::3>>
  def sized(_, _, _, _), do: <<0::3>>

  @spec charlists(charlist(), nonempty_charlist(), keyword(), keyword(integer())) :: :ok
  def charlists(_, _, _, _), do: :ok

  @spec io(iolist()) :: iodata()
  def io(x), do: x

  @spec lists([integer()], [atom(), ...], maybe_improper_list(integer(), atom())) ::
          nonempty_improper_list(atom(), binary())
  def lists(_, _, _), do: [:a | "b"]

  @spec exact_arrow((integer() -> atom())) :: (atom() -> pos_integer())
  def exact_arrow(_), do: fn _ -> 1 end

  @spec inexact_arrow((pos_integer() -> atom())) :: (... -> atom())
  def inexact_arrow(f), do: f

  @spec remote_qualified(SpecLint.Fixtures.Remote.wrap(local())) :: :ok
  def remote_qualified(_), do: :ok

  @spec opaque_remote(SpecLint.Fixtures.Remote.secret()) :: own()
  def opaque_remote(_), do: {:a}

  @spec recursive(tree()) :: tree()
  def recursive(t), do: t

  @spec correlated(x) :: x when x: atom()
  def correlated(x), do: x

  @spec same_args(x, x) :: :ok when x: atom()
  def same_args(_, _), do: :ok

  @spec maps(%{optional(atom()) => term()}, %{String.t() => integer()}, struct()) ::
          %{:a => integer(), optional(:b) => atom()}
  def maps(_, _, _), do: %{a: 1}

  @spec timeout_mfa(timeout(), mfa()) :: :ok
  def timeout_mfa(_, _), do: :ok

  @spec reduce_like([a], (a -> term())) :: :ok when a: var
  def reduce_like(_, _), do: :ok

  @spec acc_fun((integer(), acc -> acc)) :: :ok when acc: var
  def acc_fun(_), do: :ok

  @spec make_id() :: (a -> a) when a: var
  def make_id, do: fn x -> x end

  @spec covariant_arrow((integer() -> a), a) :: :ok when a: atom()
  def covariant_arrow(_, _), do: :ok

  @spec nested_arrow(((a -> term()) -> term()), a) :: :ok when a: atom()
  def nested_arrow(_, _), do: :ok

  @spec annotated(value :: atom()) :: value :: atom()
  def annotated(value), do: value

  @spec indirect(x) :: y when x: [a], y: a, a: var
  def indirect([h | _]), do: h

  @spec via_constraint(a) :: b when b: [a], a: atom()
  def via_constraint(a), do: [a]

  @spec map_mixed(%{optional(:a | integer()) => atom()}, %{required(:a | integer()) => atom()}) ::
          :ok
  def map_mixed(_, _), do: :ok

  @spec map_shared_atoms(%{optional(:a | :b) => integer(), optional(:b | :c) => atom()}) :: :ok
  def map_shared_atoms(_), do: :ok

  @spec map_shadowed(%{optional(atom()) => binary(), name: integer()}) :: :ok
  def map_shadowed(_), do: :ok

  @spec map_inexact_key(
          %{optional(timeout()) => atom()},
          %{optional(timeout()) => atom(), optional(:infinity) => binary()}
        ) :: :ok
  def map_inexact_key(_, _), do: :ok
end

defmodule SpecLint.Fixtures.Compare do
  @moduledoc false

  @spec disjoint(integer()) :: atom()
  def disjoint(x) when is_integer(x), do: x + 1

  @spec lookup(:present | :missing) :: {:ok, integer()}
  def lookup(:present), do: {:ok, 1}
  def lookup(:missing), do: {:error, :missing}

  @spec incomparable(atom() | binary()) :: :ok
  def incomparable(x) when is_atom(x) or is_integer(x), do: :ok

  @spec classify(pos_integer()) :: :positive
  def classify(n) when is_integer(n) and n > 0, do: :positive
  def classify(n) when is_integer(n), do: :nonpositive

  @spec halt(term()) :: no_return()
  def halt(x), do: {:halted, x}

  @spec rejected(atom()) :: atom()
  def rejected(x) when is_integer(x), do: x

  @spec overloaded(atom()) :: atom()
  @spec overloaded(term()) :: term()
  def overloaded(x), do: x

  @spec exact_match(:a | :b) :: :x | :y
  def exact_match(:a), do: :x
  def exact_match(:b), do: :y

  @spec private_caller(integer()) :: integer()
  def private_caller(x), do: helper(x)

  @spec helper(integer()) :: integer()
  defp helper(x), do: x

  @spec twice(term()) :: term()
  defmacro twice(x), do: x

  @spec apply_to({a}, (a -> term())) :: :ok when a: var
  def apply_to({x}, f) do
    f.(x)
    :ok
  end

  # Macro.generate_unique_arguments/2 shape (Phase 0 O5, O6): a literal 0
  # slice and a pos_integer() slice. Both erase to integer(), but the
  # overloads are disjoint.
  @spec unique_args(0, context :: atom()) :: []
  @spec unique_args(pos_integer(), context) :: [{atom(), [], context}, ...]
        when context: atom()
  def unique_args(amount, context), do: generate_args(amount, context, &{&1, [], &2})

  defp generate_args(0, context, _fun) when is_atom(context), do: []

  defp generate_args(amount, context, fun)
       when is_integer(amount) and amount > 0 and is_atom(context) do
    for id <- 1..amount, do: fun.(String.to_atom("arg" <> Integer.to_string(id)), context)
  end

  @spec ranges(1..3 | -1, atom()) :: :low
  @spec ranges(4..10, atom()) :: :high
  @spec ranges(non_neg_integer(), :x) :: :any
  def ranges(n, _) when n < 4, do: :low
  def ranges(n, _) when n <= 10, do: :high
  def ranges(_, _), do: :any

  # The second clause refers to a type that tests seed with an unsupported
  # construct; on the code path the module does not exist.
  @spec two_slices(atom()) :: atom()
  @spec two_slices(integer()) :: SpecLint.Fixtures.Synthetic.weird()
  def two_slices(x), do: x
end

defmodule SpecLint.Fixtures.Review do
  @moduledoc false

  # An inexact arrow argument (pos_integer() erased inside the fun type):
  # the translation records arrow_polarity, which excludes the slice from
  # SL001 gating (DESIGN.md section 6).
  @spec apply_it((pos_integer() -> atom()), integer()) :: :ok
  def apply_it(f, x) when is_function(f, 1) and is_integer(x), do: {:error, x}

  # The same conflict with an exact arrow argument gates.
  @spec apply_exact((integer() -> atom()), integer()) :: :ok
  def apply_exact(f, x) when is_function(f, 1) and is_integer(x), do: {:error, x}

  # A no_return() spec whose inferred return is top-only (Map.fetch!/2 on
  # an unknown map): not SL006 evidence; the ledger records the unknown
  # obligation with the reason top_only.
  @spec stop(map()) :: no_return()
  def stop(m), do: Map.fetch!(m, :k)
end

defprotocol SpecLint.Fixtures.Proto do
  @moduledoc false

  @spec describe(t()) :: String.t()
  def describe(value)
end

defmodule SpecLint.Fixtures.Behaviour do
  @moduledoc false

  @callback run(term()) :: :ok
end

defimpl SpecLint.Fixtures.Proto, for: Atom do
  def describe(atom), do: Atom.to_string(atom)
end

defmodule SpecLint.Fixtures.Generator do
  @moduledoc false

  @doc false
  defmacro define_generated do
    quote generated: true do
      @spec generated_fun(integer()) :: integer()
      def generated_fun(x), do: x
    end
  end
end

defmodule SpecLint.Fixtures.Generated do
  @moduledoc false
  alias SpecLint.Fixtures.Generator
  require Generator

  Generator.define_generated()

  @spec __call__(atom()) :: atom()
  def __call__(atom), do: atom
end

defmodule SpecLint.Fixtures.Shadow do
  @moduledoc false
  # Defines a clause the type checker reports as redundant, marked
  # generated so compiling the fixtures prints no warning (used by
  # SpecLint.ExperimentFixtures.Cases.shadowed/1). Only this clause
  # is generated: the definition (its first clause) stays in scope.

  @doc false
  defmacro redundant_clause(name) do
    quote generated: true do
      def unquote(name)(:x), do: :error
    end
  end
end

defmodule SpecLint.Fixtures.Siblings do
  @moduledoc false
  # Overloads whose second slice refers to a type that tests seed with an
  # unsupported construct (on the code path the module does not exist, so
  # the type is unresolved and the slice translates approximately).

  # Slice 0 conflicts (an atom is returned where integer() is declared).
  # Seeded, slice 1 is unsupported and so is its only argument: its domain
  # is unknown, so slice 0 may overlap it.
  @spec unsupported_sibling(atom()) :: integer()
  @spec unsupported_sibling(SpecLint.Fixtures.Synthetic.weird()) :: atom()
  def unsupported_sibling(x) when is_atom(x), do: x

  # The same conflict, but seeded slice 1 is unsupported through its
  # return only: its argument integer() is disjoint from slice 0's atom().
  @spec disjoint_sibling(atom()) :: integer()
  @spec disjoint_sibling(integer()) :: SpecLint.Fixtures.Synthetic.weird()
  def disjoint_sibling(x) when is_atom(x), do: x
  def disjoint_sibling(x) when is_integer(x), do: x
end
