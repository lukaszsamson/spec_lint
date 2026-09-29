defmodule CompilerCounterexamples.HelperInsensitivity do
  @moduledoc """
  A private helper is inferred once, under its default domain, and every
  call site gets that one signature back. When the helper returns (part of)
  its argument, the argument type is `dynamic()` inside the helper, so each
  caller's clause return degrades to `dynamic()` although the call site
  passes a literal.

  Shape of `Decimal.compare/2` (the `error/4` macro and the private
  `handle_error/4`), `Decimal.cmp/2` and `Ecto.Changeset.apply_action/2`
  (through `apply_changes/1`).
  """

  # The spec omits the {:error, :nan} return of the first clause.
  @spec sign(integer() | :nan) :: :negative | :zero | :positive
  def sign(:nan), do: handle_error(:invalid_operation, {:error, :nan})
  def sign(n) when is_integer(n) and n < 0, do: :negative
  def sign(n) when is_integer(n) and n > 0, do: :positive
  def sign(n) when is_integer(n), do: :zero

  # The same clauses without the helper: inference keeps the literal.
  @spec sign_inline(integer() | :nan) :: :negative | :zero | :positive
  def sign_inline(:nan), do: {:error, :nan}
  def sign_inline(n) when is_integer(n) and n < 0, do: :negative
  def sign_inline(n) when is_integer(n) and n > 0, do: :positive
  def sign_inline(n) when is_integer(n), do: :zero

  # Traps or returns `result`, as Decimal's handle_error/4 does.
  defp handle_error(signal, result) do
    if Process.get({__MODULE__, :trap, signal}), do: raise(ArgumentError, "#{signal}")
    result
  end
end
