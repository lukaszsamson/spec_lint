> DRAFT, NOT FILED. Reproduces on upstream 648b2a9. Read ../CHECKLIST.md
> before filing. The maintainers may prefer a PR with a failing test; a
> ready-to-paste test is below.

# list_tl over-excludes: tail of list(atom()) minus list(:y) drops [:y]

## Summary

`Module.Types.Descr.list_tl/1` on `non_empty_list(atom()) and not
non_empty_list(:y)` returns `list(atom()) and not non_empty_list(:y)`. The
list `[:x, :y]` belongs to the input and its tail `[:y]` belongs to
`non_empty_list(:y)`, so the projection excludes an achievable tail.

## Reproduction

```elixir
import Module.Types.Descr

t = opt_difference(list(atom()), list(atom([:y])))
{:ok, tl} = list_tl(t)

to_quoted_string(t)                        #=> "non_empty_list(atom()) and not non_empty_list(:y)"
to_quoted_string(tl)                       #=> "list(atom()) and not non_empty_list(:y)"
subtype?(non_empty_list(atom([:y])), tl)   #=> false
disjoint?(non_empty_list(atom([:y])), tl)  #=> true
```

## Expected

`list_tl(t)` is `list(atom())` with no exclusion: once the head is removed,
nothing is known about whether the remaining elements are all `:y`.
`disjoint?(non_empty_list(atom([:y])), tl)` should be `false`.

## Actual (Elixir 1.21.0-dev, 648b2a9, OTP 28)

As in the reproduction: the projection keeps the negative literal
`not non_empty_list(:y)` on the tail. The same happens for
`list(atom()) - list(:y or :z)`.

## Notes

- I could not trigger a wrong warning from source; the checker does not
  currently build such types from patterns. This is an algebra bug that
  will surface when negative list refinements reach `hd/1` / `tl/1`.
- `list_hd` on the same input returns `atom()`; no dual problem seen.

Suggested test for `descr_test.exs`:

```elixir
test "list_tl keeps the tails of a list difference" do
  t = opt_difference(list(atom()), list(atom([:y])))
  assert {:ok, tl} = list_tl(t)
  refute disjoint?(non_empty_list(atom([:y])), tl)
end
```

(The probe above ran with `import Module.Types.Descr`; adjust to the test
module's own imports.)
