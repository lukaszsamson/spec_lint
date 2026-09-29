# list_tl

Upstream status (648b2a9): reproduces. Kind: bug in the type algebra
(`Module.Types.Descr.list_tl/1`), latent (see impact).

`list_tl/1` keeps a negated "all elements are `:y`" constraint on the tail,
but that constraint on the whole list does not transfer to its tail. The
result claims the achievable tail `[:y]` is impossible.

Run: `elixir repro.exs`. Needs the 1.21 `Module.Types.Descr` API; prints
`not applicable` on 1.20.

Source: `UPSTREAM_BUGS.txt` item 7 (appendix).

## Expected vs actual

`t = non_empty_list(atom()) and not non_empty_list(:y)`. `[:x, :y]` belongs
to `t`; its tail is `[:y]`.

| Observation | Expected | Actual on 648b2a9 |
| --- | --- | --- |
| `to_quoted_string(list_tl(t))` | `list(atom())` | `list(atom()) and not non_empty_list(:y)` |
| `subtype?(non_empty_list(:y), list_tl(t))` | `true` | `false` |
| `disjoint?(non_empty_list(:y), list_tl(t))` | `false` | `true` |

Second shape, same bug (`list(atom())` minus `list(:y or :z)`):
`list_tl` returns `list(atom()) and not non_empty_list(:y or :z)`, which
excludes the achievable tail `[:y, :z]`.

Control: `disjoint?(non_empty_list(:y), t)` is `true` (correct), and
`list_hd(t)` is `atom()` (no dual problem seen).

## Impact and caveats

- No source-level trigger is known. The checker does not currently produce
  `list(A) and not list(B)` types from patterns, so no false warning could be
  provoked from Elixir source. It matters once negative list refinements
  reach `hd/1`/`tl/1` typing.
- The verification branch (`ls-formal-verification`) recorded the same
  finding as "List-tail projection"; the probe here reproduces it on the
  current tree without that branch's model.
- Suggested regression test: the four probe lines as a failing test in
  `lib/elixir/test/elixir/module/types/descr_test.exs`.
