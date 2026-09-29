# subpatterns_leak

Upstream status (648b2a9): reproduces. Also on 1.20.4. Kind: inference
determinism; the result is sound (a wider domain) but order-dependent.

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

Suggested direction (untested here): reset `subpatterns` in `fresh_context/1`.
`of_subpattern/4` uses `map_size(subpatterns)` as a key, so the maintainers
will know whether that is safe.
