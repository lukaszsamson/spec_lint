# The nine real omissions as executable reproducers

EXPERIMENTS.md "Real omissions found" lists nine confirmed omissions in
real code (each survived two independent refutation attempts): a function
whose `@spec` leaves out a value the body can return for an in-spec input.
The corpora are not always at hand, so each one is reproduced here in
isolation.

- Fixtures: `test/support/omission_fixtures.ex`, module
  `SpecLint.OmissionFixtures.Cases` (with the stand-in structs
  `Num`, `Conn` and `Changeset`). Each function keeps the spec, the clause
  structure and the inference-defeating construct of the original and drops
  everything else.
- Test: `test/spec_lint/omissions_test.exs` records the CURRENT class of
  each (union class and `require_static_return: true` class), whether the
  union is top-only, and the DESIRED class in a comment. The test fails when
  the class changes, in either direction, so an improvement (or a
  regression) is a visible diff: update the expected value here and in the
  test.
- The fixtures are also in the `fixtures` report
  (`bench/corpus/reports/fixtures.json`).

"Corpus revision" below is the `git rev-parse HEAD` of the library checkout
(full hashes in `bench/corpus/README.md`). "Original class" is the class of
the real function in the current `bench/corpus/reports/*.json`.

| Fixture (`Cases`), spec line | Original MFA | Corpus revision | Original file:line | Inference shape reproduced | Original class | Fixture class (union / static) | Desired |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `compare/2`, line 60 | `Decimal.compare/2` | decimal `92a28e6` | `lib/decimal.ex:491` | struct patterns with `coef: :NaN`/`:inf`; the private macro `error/4` expands to a `case` over `handle_error/2`, which is `dynamic()`, so the NaN clauses return `dynamic()`: the union is top-only and the struct returned when the trap is off is invisible | unknown (top-only) | unknown / unknown | `clause_conflict` |
| `cmp/2`, line 70 | `Decimal.cmp/2` | decimal `92a28e6` | `lib/decimal.ex:614` | pure delegation to `compare/2`, whose `(term(), term()) -> dynamic()` inference is top-only | unknown (top-only) | unknown / unknown | `clause_conflict` |
| `decode/2`, line 76 | `Plug.Conn.Query.decode/4` (fixture keeps the first two arguments) | plug `73404f8` | `lib/plug/conn/query.ex:109` | argument type too wide (`keyword()` admits atom keys), body is `Map.new(initial)` and `Enum.reduce` over `:binary.split`: `dynamic()` return, top-only | unknown (top-only) | unknown / unknown | `structured_possible` |
| `merge_private/2`, line 99 | `Plug.Conn.merge_private/2` | plug `73404f8` | `lib/plug/conn.ex:389` | struct in and out (`%{conn \| private: Enum.into(new, private)}`) with an untyped `Enumerable.t()`: the only extra is a struct-minus-struct negation with no counted component | unknown (no counted component) | unknown / unknown | `structured_possible` |
| `apply_action/2`, line 107 | `Ecto.Changeset.apply_action/2` | ecto `94d6927` | `lib/ecto/changeset.ex:2338` | `{:ok, data}` where `data` is a struct field typed `nil or map()` and the spec says `map()`; the `{:ok, nil}` component exists only as a subtraction payload (F1) and is not counted | unknown | unknown / unknown | `structured_possible` |
| `join_escape/3`, line 130 | `Ecto.Query.Builder.Join.escape/3` | ecto `94d6927` | `lib/ecto/query/builder/join.ex:47` | stale spec: 5-tuples returned, 4-tuple declared; recursive clauses and a `Macro.expand` catch-all return `dynamic()` (top-only), every parameter unguarded so each clause escapes the spec domain | possible_domain_escape | possible_domain_escape / possible_domain_escape | `clause_conflict` |
| `quoted_type/2`, line 167 | `Ecto.Query.Builder.quoted_type/2` | ecto `94d6927` | `lib/ecto/query/builder.ex:1430` | stale spec: clauses return `:atom`, `{:tuple, _}` and `{{:{}, [], _}, _}` pairs, none in `quoted_type()`; recursion through `Enum.map` and a catch-all; unguarded parameters | possible_domain_escape | possible_domain_escape / possible_domain_escape | `clause_conflict` |
| `assoc_query/4`, line 196 | `Ecto.Repo.Assoc.query/4` | ecto `94d6927` | `lib/ecto/repo/assoc.ex:11` | stale spec (`[struct()]`, elements are rows): `Enum.map(rows, fun)` with a fun spec'd `(list() -> list())`, plus a `for` over rows: `dynamic()` clauses, top-only | unknown (top-only) | unknown / unknown | `structured_possible` |
| `preloader_query/7`, line 221 | `Ecto.Repo.Preloader.query/7` | ecto `94d6927` | `lib/ecto/repo/preloader.ex:24` | stale spec (`[list()]`): `Enum.map(rows, fun)` with an untyped `fun()` and a private recursive `unextract/3`: elements are whatever `fun` returns, top-only | unknown (top-only) | unknown / unknown | `structured_possible` |

All nine fixtures reproduce the class of the original. Top-only is asserted
where it is the recorded reason (`compare/2`, `cmp/2`, `decode/2`,
`join_escape/3`, `assoc_query/4`, `preloader_query/7`). `merge_private/2`,
`apply_action/2` and `quoted_type/2` are not top-only: their reasons are
`no_counted_component`, `subtraction_payload` and `domain_escape`
respectively.

Gating recall on these nine is 0 of 9 (`clause_conflict` is the only
gating class); reported recall is 2 of 9 (`join_escape/3` and
`quoted_type/2`, class `possible_domain_escape`, reported as SL002).

## Adding or changing a reproducer

1. Edit `SpecLint.OmissionFixtures.Cases`. Keep the spec and the
   inference-defeating construct; keep the module free of compiler warnings.
2. Run `mix test test/spec_lint/omissions_test.exs`. A changed class is the
   signal; update the `@omissions` table in the test and the table above.
3. `bench/corpus/run.sh fixtures` refreshes `reports/fixtures.json`.
