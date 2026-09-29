# fun_printing

Upstream status (648b2a9): reproduces. Also on 1.20.4. Kind: printer /
algebra inconsistency; low priority.

`fun(n)` and the arrow with `none()` arguments print identically but are not
`equal?`, and the subtype relation holds in one direction only. Either the
printer should tell them apart or the algebra should identify them.

Run: `elixir repro.exs`.

Source: `UPSTREAM_BUGS.txt` item 8 (the verification branch recorded the
printer side as finding I1). The subtype direction was added while preparing
this package.

## Expected vs actual

| Observation | Actual on 648b2a9 |
| --- | --- |
| `to_quoted_string(fun(2))` | `(none(), none() -> term())` |
| `to_quoted_string(fun([none(), none()], term()))` | `(none(), none() -> term())` |
| `equal?(fun(2), fun([none(), none()], term()))` | `false` |
| `subtype?(fun(2), arrow)` | `false` |
| `subtype?(arrow, fun(2))` | `true` |
| `to_quoted_string(fun(1))`, `fun(0)` | `(none() -> term())`, `(-> term())` |

Expected: two unequal types print differently, or they are equal.
Under the usual set-theoretic semantics an arrow with a `none()` domain is a
supertype of all functions of that arity, which suggests the algebra result
(`subtype?(fun(2), arrow) == false`) is the surprising part, but the
maintainers know the intended representation; the draft asks rather than
asserts.

Impact: tools and humans reading diagnostics cannot tell "some 2-ary
function" from the bottom-argument arrow. No unsound result observed.
