# enum_map_result

Upstream status (648b2a9): reproduces. Kind: inference precision, not a bug.

`Enum.map/2` has no parametric signature, so its result is `dynamic()`
whatever the list and the mapped function. A comprehension over the same
list keeps the element shape.

Run: `elixir repro.exs` (or `/path/to/build/bin/elixir repro.exs`).

Source: `bench/corpus/compiler_counterexamples/enum_map_result.ex`,
`UPSTREAM_BUGS.txt` item 2. The reproducer adds the user-visible check
(missed warning) and prints the stdlib's own stored `Enum.map/2` signature.

## Expected vs actual

| Observation | Expected | Actual on 648b2a9 |
| --- | --- | --- |
| stored `tags/1` (`Enum.map(atoms, &{&1, :tag})`) | `dynamic(list({term(), :tag}))`, like the comprehension | `dynamic()` |
| stored `tags_for/1` (comprehension) | `dynamic(list({term(), :tag}))` | `dynamic(list({term(), :tag}))` |
| type warning on `Enum.map(...) \|> hd() \|> Kernel.+(1)` | warns, like the comprehension | no warning |
| same with `for` | warns | warns |

Runtime: `tags([:a]) == tags_for([:a]) == [a: :tag]`.

Stored signature of the standard library's `Enum.map/2` (from
`results/upstream-648b2a9/enum_map_result.txt`):

```
(not %Range{}, term()) -> dynamic()
(%Range{}, term()) -> dynamic(empty_list() or non_empty_list(term(), term()))
```

## Caveats

- Only `Enum.map/2` has a paired standalone reproducer. `Enum.reduce/3`,
  `Enum.into/2` and `Map.new/1` are known to store `dynamic()` results too
  (`Enum.reduce/3: (term(), term(), term()) -> dynamic()`), but no claim
  of identical behaviour for every operation is made without separate probes.
- A parametric signature needs generics or a hard-coded special case; the
  maintainers may already have a position on this.
- Not a soundness problem.
