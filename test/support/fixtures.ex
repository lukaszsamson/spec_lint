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

  # The second clause refers to a type that tests seed with an unsupported
  # construct; on the code path the module does not exist.
  @spec two_slices(atom()) :: atom()
  @spec two_slices(integer()) :: SpecLint.Fixtures.Synthetic.weird()
  def two_slices(x), do: x
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
