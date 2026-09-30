defmodule SpecLint.AdoptionFixtures.Order do
  @moduledoc false
  # Anonymised stand-in for a domain struct with a status field.
  defstruct id: 0, status: :active

  @type t :: %__MODULE__{id: non_neg_integer(), status: :active | :inactive | :pending}
end

defmodule SpecLint.AdoptionFixtures.Charges do
  @moduledoc false
  # Adoption regression: a genuine omission reported by a trial on a private
  # project. The first clause returns an error tuple the spec's return union
  # omits, for an in-spec input. Not part of the evaluation inventory
  # (bench/), whose 18-family denominator is unchanged. Asserted by
  # test/spec_lint/adoption_regressions_test.exs.

  alias SpecLint.AdoptionFixtures.Order

  @spec charge(Order.t(), integer()) :: {:ok, integer()} | {:error, :insufficient_funds}
  def charge(%Order{status: :inactive}, _amount), do: {:error, :order_inactive}

  def charge(%Order{}, amount) when amount > 0, do: {:ok, amount}
  def charge(%Order{}, _amount), do: {:error, :insufficient_funds}
end

defmodule SpecLint.AdoptionFixtures.Library do
  @moduledoc false
  # Stand-in for a library whose `__using__/1` injects a spec, a definition
  # and `defoverridable` (the Phoenix.View `template_not_found/2` shape).

  defmacro __using__(_opts) do
    quote do
      @spec template_not_found(binary, map) :: no_return
      def template_not_found(template, _assigns), do: raise("not found: #{template}")
      defoverridable template_not_found: 2
    end
  end
end

defmodule SpecLint.AdoptionFixtures.Consumer do
  @moduledoc false
  # Overrides the injected definition so that it returns a binary; the
  # injected spec stays attached (correct finding, library-owned spec).
  use SpecLint.AdoptionFixtures.Library

  def template_not_found(template, _assigns), do: "missing template " <> template

  # A spec written next to its definition: never reported as inherited.
  @spec own_spec(integer()) :: no_return()
  def own_spec(value), do: value + 1
end

defmodule SpecLint.AdoptionFixtures.KeepLibrary do
  @moduledoc false
  # A macro that injects a spec from `quote location: :keep`.

  defmacro kept_spec do
    quote location: :keep do
      @spec kept(integer()) :: atom()
    end
  end
end

defmodule SpecLint.AdoptionFixtures.Evaluated do
  @moduledoc false
  # A spec the module builds itself from an AST without line metadata
  # (here a `quote` evaluated in the module body; `Code.string_to_quoted!/1`
  # gives the same annotation) carries the bare default line 1, not a
  # macro call line: it is owned by the module and must not be reported as
  # inherited. A spec injected with `quote location: :keep` still carries
  # the bare call line.
  alias SpecLint.AdoptionFixtures.KeepLibrary
  require KeepLibrary

  Code.eval_quoted(quote(do: @spec(from_quote(integer()) :: atom())), [],
    module: __MODULE__,
    file: __ENV__.file
  )

  def from_quote(value), do: value + 1

  KeepLibrary.kept_spec()
  def kept(value), do: value + 1
end
