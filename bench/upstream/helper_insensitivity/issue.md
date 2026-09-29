> DRAFT, NOT FILED. Reproduces on upstream 648b2a9. Read ../CHECKLIST.md
> before filing. Suggested venue: elixir-lang-core or a GitHub discussion
> rather than an issue, since this is a precision request.

# Local helper indirection loses a literal return shape that is preserved when the helper is inlined

## Summary

A private function is inferred once and every caller gets that one
signature. If the function returns (part of) an argument, the argument is
`dynamic()` inside it, so a call with a literal argument also returns
`dynamic()`. Writing the helper's body inline keeps the literal.

## Reproduction

```elixir
defmodule HelperInsensitivity do
  defp handle_error(signal, result) do
    if Process.get({__MODULE__, :trap, signal}), do: raise(ArgumentError, "#{signal}")
    result
  end

  def sign(:nan), do: handle_error(:invalid_operation, {:error, :nan})
  def sign(n) when is_integer(n) and n < 0, do: :negative
  def sign(n) when is_integer(n) and n > 0, do: :positive
  def sign(n) when is_integer(n), do: :zero

  def sign_inline(:nan), do: {:error, :nan}
  def sign_inline(n) when is_integer(n) and n < 0, do: :negative
  def sign_inline(n) when is_integer(n) and n > 0, do: :positive
  def sign_inline(n) when is_integer(n), do: :zero

  def with_helper, do: handle_error(:invalid_operation, {:error, :nan}) + 1
  def inlined, do: (r = {:error, :nan}; if(Process.get({__MODULE__, :trap, :invalid_operation}), do: raise(ArgumentError, "invalid_operation")); r + 1)
end
```

Attached script `repro.exs` compiles this and prints the stored ExCk
signatures and which functions got a type warning.

## Expected

`sign/1` stores `(:nan) -> {:error, :nan}` like `sign_inline/1`, and
`with_helper/0` warns like `inlined/0` ("incompatible types given to
Kernel.+/2").

## Actual (Elixir 1.21.0-dev, 648b2a9, OTP 28)

```
stored sign/1: (:nan) -> dynamic()
stored sign_inline/1: (:nan) -> {:error, :nan}
type warning on with_helper/0 (helper call): false
type warning on inlined/0 (helper body written out): true
```

## Notes

- Not a soundness problem: `dynamic()` is a valid over-approximation.
- The same happens with `Decimal.compare/2` (its `error/4` macro and private
  `handle_error/4`) and `Ecto.Changeset.apply_action/2`.
- I am not asking for unrestricted re-inference of every callee. Is
  preserving argument-to-return relationships, or specializing selected
  local calls, something already planned or considered too expensive?
