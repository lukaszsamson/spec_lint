# for_into_narrowing

Upstream status (648b2a9): reproduces. Absent on the fork (c24c235).
Kind: soundness bug (a stored signature excludes an accepted argument) and
false-positive warnings. The strongest item in this package.

`for ... into: into` where `into` may be `[]` or a bitstring narrows the
comprehension body (and the variables in it) to `bitstring()`. The list path
accepts any element.

Run: `elixir repro.exs`.

Source: `UPSTREAM_BUGS.txt` item 11; `test/spec_lint/upstream_qualification_test.exs`
pins it per revision. `fix.patch` is the fork's fix (fork commit
c24c23538 "Fix incorrect narrowing in mixed type for into", diff against its
parent, code and test); `git apply --check` accepts it on 648b2a9. Its test
suite was not re-run on 648b2a9.

## Expected vs actual

`f(flag, value)` accepts any `value` and returns it; `f(true, :ok)` returns
`:ok` at runtime.

| Observation | Expected | Actual on 648b2a9 | Fork c24c235 |
| --- | --- | --- | --- |
| stored `f/2` | `(term(), term()) -> dynamic()` | `(term(), bitstring()) -> dynamic(bitstring())` | `(term(), term()) -> dynamic()` |
| warning on the body `for _ <- [1], do: value, into: into` (literal `:ok`) | none | "expected the body of a for-comprehension with into: binary() (or bitstring()) to be a binary (or bitstring)" | none |
| warning on the call `f(true, :ok)` | none | "incompatible types given to f/2 ... expected one of: term(), bitstring()" | none |
| stored `literal/1` | `dynamic(binary() or list(:ok))` | `dynamic()` | `dynamic(binary() or list(:ok))` |

Cause: `for_into/5` in `lib/elixir/lib/module/types/expr.ex` returns
`bitstring()` as the body's expected type when the collectable may be a
bitstring, even when it may also be an empty list. The fix returns `term()`
for that case and reports `badbitbody` only when the list path is impossible.

Also 1.20.4 does not reproduce (its `f/2` stores `(term(), term())`).
