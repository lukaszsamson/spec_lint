# Compiler counterexamples

Minimal modules for discussing two inference limits of the Elixir type
checker with its maintainers. Each module compiles without warnings on the
qualified toolchain (Elixir 1.21.0-dev `c24c235`, OTP 28), has a spec that
omits a return, and a runtime witness. They are not part of the SpecLint
build and do not depend on it.

```sh
elixir bench/corpus/compiler_counterexamples/check.exs
```

compiles them into a temporary directory, prints the signature the
compiler stores in each checker chunk (`ExCk`), runs the witnesses, and
raises if an observation differs from the tables below.

These two limits block 7 of the 8 known omissions SpecLint misses
(`EXPERIMENTS.md`, "Recall on the nine known omissions"; `STATUS.md`,
"Next steps", items 1 and 2). Neither is a SpecLint defect: SpecLint
reads the stored signature and cannot recover what inference discarded.

## 1. Helper insensitivity (`helper_insensitivity.ex`)

A private helper is inferred once, under its default domain. Inside it,
its parameters are `dynamic()`, so a helper that returns (part of) its
argument returns `dynamic()`, and every caller gets that back, even for a
literal argument.

| Function | Stored signature | SpecLint |
| --- | --- | --- |
| `sign/1`, `:nan` clause through `handle_error/2` | `(:nan) -> dynamic()`; `(integer()) -> :negative or :positive or :zero` | no finding (`top_only`) |
| `sign_inline/1`, same clauses without the helper | `(:nan) -> {:error, :nan}`; `(integer()) -> :negative or :positive or :zero` | SL001 `clause_conflict`, gates |

Witness: `sign(:nan)` returns `{:error, :nan}`, outside
`:negative | :zero | :positive`; control `sign(-1)` returns `:negative`.

What would help: inferring a local helper at its call site (or storing a
return that is a function of the argument, `(a -> a)`), so `sign/1`'s first
clause stores `{:error, :nan}` as `sign_inline/1`'s does. Originals:
`Decimal.compare/2` (the `error/4` macro and the private `handle_error/4`),
`Decimal.cmp/2` (delegates to `compare/2`), `Ecto.Changeset.apply_action/2`
(through `apply_changes/1`).

## 2. `Enum.map/2` results (`enum_map_result.ex`)

`Enum.map/2` has no parametric signature, so its result is `dynamic()`
whatever the list and the mapped function. A comprehension over the same
list keeps the element shape.

| Function | Stored signature | SpecLint |
| --- | --- | --- |
| `tags/1`, `Enum.map(atoms, fn atom -> {atom, :tag} end)` | `(empty_list() or non_empty_list(term(), term())) -> dynamic()` | no finding (`top_only`) |
| `tags_for/1`, `for atom <- atoms, do: {atom, :tag}` | `(...) -> dynamic(list({term(), :tag}))` | no finding (`no_counted_component`) |

Witness: `tags([:a])` returns `[a: :tag]`, outside `[atom()]`; control
`tags([])` returns `[]`. `tags_for/1` shows the shape the compiler can
already infer. SpecLint still cannot report it: `[]` is in both the spec
and the inferred list type, and a list whose element type is wrong is not
a component SpecLint counts. That second limit is SpecLint's, recorded in
`STATUS.md`.

What would help: parametric signatures for `Enum.map/2` (and
`Enum.reduce/3`, `Enum.into/2`, `Map.new/1`), so `tags/1` stores
`list({term(), :tag})` like `tags_for/1`. Originals:
`Ecto.Repo.Assoc.query/4`, `Ecto.Repo.Preloader.query/7`,
`Plug.Conn.Query.decode/4` (`Map.new/1`, `Enum.reduce/3`) and
`Plug.Conn.merge_private/2` (`Enum.into/2`).
