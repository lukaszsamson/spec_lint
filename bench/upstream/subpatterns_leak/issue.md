> DRAFT, NOT FILED. Reproduces on upstream 648b2a9. Read ../CHECKLIST.md
> before filing. Sound but non-deterministic in the sense described; the
> maintainers may consider the imprecision acceptable.

# Module.Types: `subpatterns` is not reset between definitions, so a function's signature depends on unrelated earlier definitions

## Summary

Two functions with identical source get different inferred signatures
depending on whether an unrelated function with a list pattern is defined
before them in the same module.

## Reproduction

```elixir
defmodule LeakWith do
  def a([x | _]), do: x
  def b(y) when is_list(y), do: 1
  def b(z), do: z
end

defmodule LeakWithout do
  def b(y) when is_list(y), do: 1
  def b(z), do: z
end
```

Compile and read the `ExCk` chunk (`repro.exs` does this).

## Expected

`LeakWith.b/1` and `LeakWithout.b/1` store the same signature.

## Actual (Elixir 1.21.0-dev, 648b2a9, OTP 28)

```
LeakWithout.b/1: empty_list() or non_empty_list(term(), term()) -> integer()
                 not empty_list() and not non_empty_list(term(), term()) -> dynamic(not ...)
LeakWith.b/1:    empty_list() or non_empty_list(term(), term()) -> integer()
                 term() -> dynamic()
```

## Analysis

`fresh_context/1` (`lib/elixir/lib/module/types.ex`) resets `vars`,
`failed` and `reverse_arrows` but not `subpatterns`. `a/1`'s list pattern
records `{:list, version}` in `context.subpatterns`; the guard `is_list(y)` in
`b/1` finds an entry for the same variable version (`list_subpattern?/2` in
`pattern.ex`) and is treated as imprecise, so clause 0 is not subtracted from
clause 1. The result is a wider, still sound, domain, but it depends on
definition order.

## Question

Is the leak intentional (a cheap conservative fallback)? If not, should
`fresh_context/1` reset `subpatterns`?
