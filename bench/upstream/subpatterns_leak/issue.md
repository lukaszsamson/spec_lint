> HISTORICAL DRAFT, NOT FILED. The behavior is inference precision loss,
> not demonstrated unsoundness or nondeterministic compilation. The simple
> reset proposed below was challenged and crashes an existing compiler test;
> see [the independent review](../review-2026-09-29.md). A human must review
> current behavior and duplicates before submitting any revised report.

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
unrelated definitions and inference order. It is deterministic for a given
module; textual declaration order alone need not control inference order.

## Review update and question

A temporary patch adding only `subpatterns: %{}` to `fresh_context/1`
removed this witness, but crashed the existing compiler test
`Module.Types.IntegrationTest."test ExCk chunk writes exports for implementations"/1`
with a `MatchError` in `Module.Types.Pattern.of_pattern_var/3`. The unpatched
compiler passed 541 tests (7 doctests, 534 tests). This refutes the draft’s
simple reset as a validated fix direction; no safe patch is proposed.

Is this precision loss intentional, or should inference state be preserved
and restored at a different boundary? The
[independent review](../review-2026-09-29.md) records focused controls and
commands. No unsoundness was demonstrated.
