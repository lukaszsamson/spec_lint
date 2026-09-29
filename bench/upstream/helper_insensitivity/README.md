# helper_insensitivity

Upstream status (648b2a9): reproduces. Kind: inference precision, not a bug.

A private helper is inferred once, under its default domain, and each call
site gets that one signature back. When the helper returns (part of) its
argument, the argument is `dynamic()` inside the helper, so every caller's
clause return degrades to `dynamic()` even when the call site passes a
literal.

Run: `elixir repro.exs` (or `/path/to/build/bin/elixir repro.exs`).

Source of the finding: `bench/corpus/compiler_counterexamples/helper_insensitivity.ex`
and `UPSTREAM_BUGS.txt` item 1. The reproducer here is the same pair, with
the specs dropped (they play no role) and a user-visible check added.

## Expected vs actual

| Observation | Expected (inlined behaviour) | Actual on 648b2a9 |
| --- | --- | --- |
| stored `sign/1`, first clause | `(:nan) -> {:error, :nan}` | `(:nan) -> dynamic()` |
| stored `sign_inline/1`, first clause | `(:nan) -> {:error, :nan}` | `(:nan) -> {:error, :nan}` |
| type warning on `handle_error(..., {:error, :nan}) + 1` | warns, like the written-out body | no warning |
| type warning on the same body written out | warns | warns |

Runtime is identical for both functions: `sign(:nan) == sign_inline(:nan) == {:error, :nan}`.

Actual output (`results/upstream-648b2a9/helper_insensitivity.txt`):

```
type warning on with_helper/0 (helper call): false
type warning on inlined/0 (helper body written out): true
stored sign/1: (:nan) -> dynamic()
stored sign/1: (integer()) -> :negative or :positive or :zero
stored sign_inline/1: (:nan) -> {:error, :nan}
stored sign_inline/1: (integer()) -> :negative or :positive or :zero
VERDICT: reproduces
```

## Caveats for the maintainer discussion

- `dynamic()` is a sound over-approximation. Nothing here is unsound.
- The consumer that motivated this is a tool reading stored signatures
  (Decimal.compare/2, Decimal.cmp/2 and Ecto.Changeset.apply_action/2 have
  this shape). The user-visible cost is a missed warning like the one above.
- Do not ask for unrestricted re-inference of every callee: recursion, code
  size and compile time are real costs. The ask is a discussion of
  argument-to-return relationships (`(a -> a)`) or selective call-site
  specialization.
