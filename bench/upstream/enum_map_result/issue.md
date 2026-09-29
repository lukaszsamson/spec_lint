> DRAFT, NOT FILED. Reproduces on upstream 648b2a9. Read ../CHECKLIST.md
> before filing. Suggested venue: elixir-lang-core or a GitHub discussion.
> Keep it separate from the helper-specialization draft.

# Preserve mapped result shape through Enum.map/2

## Summary

`Enum.map/2` returns `dynamic()` to the type checker regardless of the
mapped function, while an equivalent `for` comprehension keeps the element
type. Code using `Enum.map/2` therefore misses diagnostics that the
comprehension form gets.

## Reproduction

```elixir
defmodule EnumMapResult do
  def tags(atoms) when is_list(atoms), do: Enum.map(atoms, fn atom -> {atom, :tag} end)
  def tags_for(atoms) when is_list(atoms), do: for(atom <- atoms, do: {atom, :tag})

  def mapped, do: Enum.map([:a], fn a -> {a, :tag} end) |> hd() |> Kernel.+(1)
  def comprehension, do: (for a <- [:a], do: {a, :tag}) |> hd() |> Kernel.+(1)
end
```

`repro.exs` compiles this, prints the stored signatures, and reports which
of `mapped/0` and `comprehension/0` got a type warning.

## Expected

`tags/1` stores `dynamic(list({term(), :tag}))` like `tags_for/1`, and
`mapped/0` warns like `comprehension/0`.

## Actual (Elixir 1.21.0-dev, 648b2a9, OTP 28)

```
stored tags/1: (empty_list() or non_empty_list(term(), term())) -> dynamic()
stored tags_for/1: (empty_list() or non_empty_list(term(), term())) -> dynamic(list({term(), :tag}))
type warning on mapped/0 (Enum.map): false
type warning on comprehension/0 (for): true
stored Enum.map/2: (not %Range{}, term()) -> dynamic()
```

## Question

Are parametric (or special-cased) signatures for `Enum.map/2` and related
higher-order functions (`Enum.reduce/3`, `Enum.into/2`, `Map.new/1`)
planned? This is a precision request, not a soundness report.
