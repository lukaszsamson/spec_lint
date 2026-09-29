# subpatterns_leak

Upstream status (648b2a9): reproduces. Also on 1.20.4. Kind: inference
precision; the result is sound (a wider domain) and depends on unrelated
definitions and inference order. It is deterministic for a given module;
textual declaration order alone need not control inference order.

`Module.Types` does not reset `context.subpatterns` between clauses or
definitions (`fresh_context/1`, `types.ex:708-710`). The `{:list, version}`
entry a list pattern in one definition leaves behind makes the guard
`is_list(y)` in a later definition, on a variable of the same version,
imprecise (`pattern.ex:990-996`). The compiler then subtracts fewer previous
clauses than a fresh run would.

Run: `elixir repro.exs`. `subpatterns_leak.ex` is the original reproducer
from `bench/clause_mapping/` (compile it with `elixirc`).

Source: Milestone 4, `bench/clause_mapping/README.md` finding E1, and
`bench/clause_mapping/subpatterns_leak.ex`.

## Expected vs actual

`LeakWith.b/1` and `LeakWithout.b/1` have identical source; the only
difference is that `LeakWith` defines `a([x | _])` first.

| Function | Expected (identical) | Actual on 648b2a9 |
| --- | --- | --- |
| `LeakWithout.b/1` | `list -> integer() ; not list -> dynamic(not list)` | `list -> integer() ; not list -> dynamic(not list)` |
| `LeakWith.b/1` | same | `list -> integer() ; term() -> dynamic()` |

The stored domain of clause 1 in `LeakWith` is `term()` instead of `not list`.

Impact: a clause's stored domain (and the clause partition of the stored
signature) depends on unrelated earlier definitions, so head types cannot be
recomputed from a clause's own head alone. That defeats consumers that map
stored clauses back to source clauses (see `checker_chunk_api`). On the
fifteen corpora the fresh head differs from the compiler's in 119 of 3,237
functions where both were recorded.

## Adversarial review update (2026-09-29)

The original reset suggestion has been refuted as a validated fix direction.
Adding only `subpatterns: %{}` to `fresh_context/1` removes this witness,
but crashes the existing compiler test
`Module.Types.IntegrationTest."test ExCk chunk writes exports for implementations"/1`
with a `MatchError` in `Module.Types.Pattern.of_pattern_var/3`. The unpatched
compiler passed 541 tests (7 doctests, 534 tests). Focused controls support
incidental inference-state precision loss; no unsoundness was demonstrated.
Report the behavior and ask maintainers to assess the appropriate state
boundary. See [the independent review](../review-2026-09-29.md) for commands
and evidence. No final fix or full-suite safety claim is made.
