> HISTORICAL DRAFT, NOT FILED BY THIS PACKAGE. DO NOT FILE A DUPLICATE.
> Existing upstream report: [#15950](https://github.com/elixir-lang/elixir/issues/15950) and
> [PR #15952](https://github.com/elixir-lang/elixir/pull/15952).
> Retained for evidence; see [the independent review](../review-2026-09-29.md).

# for-comprehension with a bitstring-or-list :into narrows the body variables to bitstring()

## Summary

When the `:into` value may be either `[]` or a bitstring, the type checker
requires the comprehension body to be a bitstring. The list path accepts any
element, so the requirement is wrong: it produces false warnings and a stored
signature that excludes an argument the function accepts.

## Reproduction

```elixir
defmodule IntoProbe do
  def f(flag, value) do
    into = if flag, do: [], else: ""
    _ = for _ <- [1], do: value, into: into
    value
  end

  def literal(flag) do
    into = if flag, do: [], else: ""
    for _ <- [1], do: :ok, into: into
  end

  def caller, do: f(true, :ok)
end
```

`IntoProbe.f(true, :ok)` returns `:ok`, and `IntoProbe.literal(true)`
returns `[:ok]`.

## Expected

No warnings; `f/2` stores `(term(), term()) -> dynamic()`.

## Actual (Elixir 1.21.0-dev, 648b2a9, OTP 28)

```
warning: expected the body of a for-comprehension with into: binary() (or bitstring()) to be a binary (or bitstring): :ok ... but got type: :ok
warning: incompatible types given to f/2: f(true, :ok) ... but expected one of: term(), bitstring()
stored f/2: (term(), bitstring()) -> dynamic(bitstring())
```

The stored domain (second argument `bitstring()`) excludes `:ok`, which the
function accepts: a soundness problem, not just a precision loss.

## Analysis

`for_into/5` in `lib/elixir/lib/module/types/expr.ex` returns `bitstring()`
as the body's expected type when the collectable may be a bitstring, even if
it may also be an empty list. The attached patch returns `term()` for that
case and only reports `badbitbody` when the list path is impossible, with
regression tests in `expr_test.exs`.
