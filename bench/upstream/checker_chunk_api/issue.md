> DRAFT, NOT FILED. The gap exists on upstream 648b2a9. Read ../CHECKLIST.md
> before filing. This is a feature request: suggest a discussion first, and
> keep it separate from the bug reports. The maintainers may prefer not to
> extend the chunk format; ask before writing code.

# Feature request: source-clause mapping and per-clause reachability in the checker chunk

## Summary

Tools that read the inferred signatures in the `ExCk` chunk cannot relate a
stored clause to the source clause(s) it came from, and cannot learn which
source clauses the checker found redundant. Today the only route is to
re-run the checker on the debug info and parse free-text warnings.

## Reproduction

```elixir
defmodule ClauseGap do
  def merged(:a), do: 1
  def merged(:b), do: 1
  def merged(:c), do: :x

  def dropped(:a), do: :ok
  def dropped(:b), do: raise("boom")

  def redundant(x) when is_atom(x), do: 1
  def redundant(:a), do: 2
  def redundant(_), do: 3
end
```

After compiling, the debug info has 3, 2 and 3 source clauses; the chunk
stores 2, 1 and 1 clauses. The export entries have the single key `:sig`,
and the redundancy of `redundant(:a)` is available only as the compiler
warning.

## Requested

For each function in the chunk:

1. the source clause indices behind each stored clause (or a marker that a
   clause was dropped, as `group_clauses/1` does for always-raising clauses);
2. a per-source-clause reachability verdict: `:reachable | :redundant |
   :unused | :unknown`, with `:unknown` meaning only that no diagnostic was
   produced.

`group_clauses/1`, `add_inferred/5` and `group_clauses_by_return/1` in
`Module.Types` already perform the merging and dropping, so this looks like
carrying indices through them.

## Motivation

A spec-versus-implementation checker reads the stored signature and needs to
say which source clause causes a mismatch, and to avoid reporting returns
of clauses the checker proved unreachable. Recomputing clause heads from
outside is unsound in several documented cases (see the `subpatterns`
leak report), so structural cases are the only ones a consumer can trust:
93.5% of functions in fifteen open-source projects, not the merged or
dropped ones.

## Alternatives

A documented function (for example on `Module.Types`) returning the same
data for a compiled module, if extending the chunk is undesirable.
