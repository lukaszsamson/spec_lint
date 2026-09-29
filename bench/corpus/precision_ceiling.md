# Can a stronger input lower bound improve the nine omission fixtures?

Run `MIX_ENV=test mix compile`, then:

```sh
elixir -pa _build/test/lib/spec_lint/ebin bench/precision_ceiling.exs -- \
  --out bench/corpus/precision_ceiling.json
```

The committed [JSON result](precision_ceiling.json) uses the pinned
`1.21.0-dev+c24c235` adapter and the nine stand-in functions in
`test/support/omission_fixtures.ex`. The experiment compares each contributing
stored inferred clause's *whole argument tuple* `I` with the translated spec
input bounds `D_lo ⊆ D ⊆ D_hi`. A sound lower-bound improvement can prove
`I ⊆ D` only if `I ⊆ D_hi` already holds. This is a necessary condition,
not a sufficient one.

| Fixture | Exact inputs? | Empty `D_lo`? | Contributing clauses | `I ⊆ D_hi` |
| --- | --- | --- | ---: | ---: |
| `compare/2` | no | yes | 6 | 0 |
| `cmp/2` | no | yes | 1 | 0 |
| `decode/2` | yes | no | 1 | 0 |
| `merge_private/2` | no | no | 1 | 0 |
| `apply_action/2` | yes | no | 1 | 0 |
| `join_escape/3` | no | yes | 6 | 0 |
| `quoted_type/2` | no | no | 11 | 0 |
| `assoc_query/4` | yes | no | 3 | 0 |
| `preloader_query/7` | yes | no | 3 | 0 |

All 33 contributing clause domains **overlap** `D_hi` but extend outside it.
None is contained in `D_lo` either. Thus retaining a larger sound `D_lo`
alone cannot establish containment for any of the current stored clauses.
The result does not rule out refining a clause domain under a spec assumption,
splitting it by input region, or improving compiler inference. The Phase 2
body run did narrow a clause of `quoted_type/2` enough to gate its omission.

The individual argument measurements in the JSON show the blockers. For
`compare/2`, a `%Num{coef: :NaN}` pattern leaves required `sign` and `exp`
fields unconstrained, and its catch-all accepts `term()` in another position.
`Num.t()` also requires `sign: 1 | -1` and a nonnegative coefficient; these
integer refinements make `D_lo` empty in the current lattice. A nonempty
lower bound for those fields would need a richer representation or a sound
value subset; simply retaining map structure cannot turn `integer()` into
a subset of `1 | -1`.

For `merge_private/2` and `apply_action/2`, `D_lo` is already nonempty, but
the inferred `%Conn{}` and `%Changeset{valid?: term()}` domains allow field
values outside their typed struct specs. The exact-input examples
`decode/2`, `assoc_query/4`, and `preloader_query/7` show the same ceiling
without any translation loss: unguarded arguments are inferred as `term()`
or broad lists. `join_escape/3` has an empty lower bound because of
`Macro.Env.t()` integer refinements, yet every stored clause also escapes
through unguarded `vars` and `env` arguments.

This measures the nine fixtures and the current ExCk signatures only. It
does not estimate the value of a lower-bound improvement on other code or
after an inference change. Re-run the script if the compiler, translator, or
fixtures change; the omission test independently checks the bound relation
and the escape of every contributing clause.
