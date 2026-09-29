# Ash and Nx holdout triage

This review uses the pinned revisions in `expansion.json`: Ash
`164a4c0d0ef7724c5fd2153876c2cf90cd938863` and Nx
`a0076029fe98f851c0183e2fb47d58de3d4bcb34`. The inputs are
`reports/expansion/{ash,nx}.spec_lint.json`. Ash completed with 990 compared
functions, 992 compared slices, 12 informational findings, and no CI gate.
Nx completed with 7 compared functions, 9 compared slices, and no findings.
No classifier or compiler behavior was changed after opening these holdouts.

“Confirmed” below means the source supplies a path for an input allowed by the
spec to return an undeclared value. “Witnessed” means a runtime call with an
input inside the declared spec returned a value outside the declared return,
with a paired in-domain control that stays inside it (the direct witnesses in
`holdout_witnesses.exs` and the integration witnesses in
`ash_integration_witnesses.exs`). “Probable” needs an end-to-end witness for
reachability. “Refuted” means the inferred alternative comes from a wider
callee or path than the caller can take, or that a witness aimed at the
alternative returned inside the declared return. “Still unconfirmed” means a
witness could not be built; the reason is stated. All 12 emitted findings were non-gating
under the policy of this triage, regardless of this human judgment. Since the
clause-local qualification became the default (Close phase, 2026-09-29,
`clause_local_qualification.md`), `Ash.Page.page_opts/1` gates; the other 11 do not.

Correction (2026-09-29 review): the integration witnesses first built
`Ash.Query` and `Ash.Policy.Authorizer` inputs whose default-`nil` fields
(`distinct`, `timeout`, `subject`, the scenario lists) are outside the declared
struct types, although the text said every field was valid. The script now
checks each input against the cited types (`Support.query_t?/1`,
`Support.authorizer_t?/1`, `Support.valid_keyset_page?/1`), repairs the inputs
where an in-domain value exists, and records `*_input_in_declared_domain` per
observation. `page/2` and `solve/1` keep their verdicts with repaired inputs;
`Query.apply_to/3` has no in-domain witness and is downgraded below.

| Finding | Judgment | Source and reason |
| --- | --- | --- |
| `Ash.page/2` SL002 domain escape | **Witnessed (integration)** | `ash/lib/ash.ex:2204-2232,2270-2328`: the spec allows integer requests on a `Keyset` page, yet that clause returns `{:error, binary()}`; `Ash.Error.t()` is an exception type. Integration witness: a `%Ash.Page.Keyset{}` read from an ETS resource with `page: [limit: 1, count: true]`, whose rerun query is repaired to `distinct: []` and `timeout: nil` (as read it has `nil` and `:infinity`, outside `Ash.Query.t()`), so that every `Keyset.t()` field and the checked `Ash.Query.t()` fields are valid; request `3` returned `{:error, "Cannot seek to a specific page with keyset based pagination"}`; the control `Ash.page(page, :self)` returned `{:ok, %Ash.Page.Keyset{}}`. The paths delegating to `read/2` can also relay its third query element (not separately witnessed). |
| `Ash.load/3` SL002 domain escape | **Confirmed, witnessed** | `ash/lib/ash.ex:2446-2454`: `:ok` is an allowed first input and the clause returns `{:ok, :ok}`. The declared successful payload is a resource record, list of records, or nil; `Ash.Resource.record()` is `struct()` (`ash/lib/ash/resource.ex:13`). |
| `Ash.data_layer_query/2` SL002 domain escape | **Refuted (integration witness)** | `ash/lib/ash.ex:2660-2664` calls `read/2` with `data_layer_query?: true`. Its inferred extra is a three-tuple. `ash/lib/ash/actions/read/read.ex:415-425,1040-1060,1160-1178` takes a dedicated query-building branch that returns two-tuples, and the only three-tuple constructor, `add_query/3` (`read.ex:2819-2825`), has a single call site (`read.ex:508`) in the `else` of that branch. Integration witness: `Ash.data_layer_query(Ash.Query.new(Post), return_query?: true)` on a validated ETS resource returned `{:ok, %{query: _, ash_query: _, count: _, run: _, load: _}}`, inside the declared `{:ok, data_layer_query}`, identical in shape to the control without the option. The extra is spillover from `read/2`'s union. |
| `Ash.read/2` SL002 domain escape | **Witnessed (integration)** | `ash/lib/ash.ex:108-117,2761-2794`: `return_query?: true` is a documented valid option. The `{:ok, results, query}` case returns a three-tuple even though the spec lists only two-tuples. `ash/lib/ash/actions/read/read.ex:2819-2825` constructs that form. Integration witness: `Ash.read(Post, return_query?: true)` returned `{:ok, [%Post{}], %Ash.Query{}}`; the control without the option returned `{:ok, [%Post{}]}`. |
| `Ash.read_one/2` SL002 domain escape | **Witnessed (integration)** | `ash/lib/ash.ex:163-174,2912-2934`: the valid `return_query?` option passes through the read-one schema, and the function explicitly returns `{:ok, result, query}`. `ash/lib/ash/helpers.ex:318-325` preserves the third element. Integration witness: `Ash.read_one(Post, return_query?: true)` returned `{:ok, %Post{}, %Ash.Query{}}`; the control returned `{:ok, %Post{}}`. |
| `Ash.read_first/2` SL002 domain escape | **Witnessed (integration)** | `ash/lib/ash.ex:2991-3012` uses the same read-one options and `do_read_one/3`; its `{:ok, result, query}` case also returns an undeclared third element. Integration witness: `Ash.read_first(Post, return_query?: true)` returned `{:ok, %Post{}, %Ash.Query{}}`; the control returned `{:ok, %Post{}}`. |
| `Ash.Page.page_opts/1` SL001 clause conflict | **Confirmed, witnessed** | `ash/lib/ash/page/page.ex:11-20`: both `false` and `nil` are explicitly in the input spec, but their clause returns `{:ok, false}` and `{:ok, nil}` rather than `{:ok, page()}`. It did not gate under the slice-wide arrow prerequisites; it gates under the clause-local qualification, now the default. The catch-all clause also escapes (not reported by SpecLint): `validate_or_error/2` returns `{:ok, mod.to_options(value)}`, a keyword list, so no input returns `{:ok, page()}` (`[limit: 1]` returned `{:ok, [limit: 1]}` on the pinned build); see `clause_local_qualification.md`. |
| `Ash.Policy.Policy.solve/1` SL002 domain escape | **Witnessed (integration)** | `ash/lib/ash/policy/policy.ex:75-98` returns `{:error, authorizer, :unsatisfiable}` when the solver yields no scenarios; the spec requires an `Ash.Error.t()` third element. Integration witness: an `Authorizer.t()` built from `Ash.Policy.Authorizer.initial_state/4` (which leaves `subject` and the three scenario lists at `nil`, outside `Authorizer.t()`) with `subject` set to an in-domain `Ash.Query.t()` and the scenario lists to `[]`, for a resource with two applicable policies, `authorize_if CheckA` and `authorize_if CheckB`, returned `{:error, %Ash.Policy.Authorizer{}, :unsatisfiable}`; the control with only `CheckA` returned `{:ok, [%{{CheckA, []} => true}], %Ash.Policy.Authorizer{}}`. Reachability needs a check that stays `:unknown` at strict-check time and declares `conflicts?/3` (here two user-defined `Ash.Policy.Check` modules): every builtin check decides during the strict check, so builtin-only policies fold to a boolean (`{:ok, false, authorizer}` in the attempts made with `actor_present`/`actor_absent`, and with `expr(...)` versus its negation). The public authorization flow maps this result to `Ash.Error.Forbidden.Policy` (`authorizer.ex:1755-1761`), so the escape is at the `solve/1` boundary, not at the user-facing API. |
| `Ash.Query.apply_to/3` SL002 domain escape | **Probable (escape observed only outside the declared domain)** | `ash/lib/ash/query/query.ex:4346-4373` has an `else {:error, error} -> {:error, Ash.Error.to_ash_error(error)}` branch, while its spec promises only `{:ok, records}`. `Ash.Query.apply_to(Ash.Query.load(query, :exploding), records, domain: Domain)`, where `:exploding` is a calculation whose `calculate/3` returns `{:error, _}`, returned `{:error, %Ash.Error.Unknown{}}` (control with a well-behaved calculation: `{:ok, [%Post{}]}`). That query is not an `Ash.Query.t()`: the type declares `calculations: %{optional(atom) => :wat}` (`query.ex:206-246`), and loading any calculation stores an `%Ash.Query.Calculation{}` there, so no query that reaches the error through a loaded calculation is in the declared domain. An in-domain error path was not found. |
| `Ash.Resource.Info.sortable?/3` SL002 domain escape | **Refuted** | `ash/lib/ash/resource/info.ex:911-965`: the case clauses return `true` or `false`, including its default. No path returning the inferred `nil` was found. This is propagated call imprecision, not a demonstrated missing alternative. |
| `Ash.Test.refute_has_error/3` SL002 domain escape | **Confirmed, witnessed** | `ash/lib/ash/test.ex:109-122`: the spec allows `:ok` input but the first clause returns `:ok`, outside `Ash.Error.t() | no_return()`. Passing `Ash.Error.Invalid` as the deprecated class argument keeps the witness inside the declared domain. |
| `Ash.UUIDv7.generate/0` SL002 structured possible | **Refuted** | `ash/lib/ash/uuid_v7.ex:49-76,95-122`: `bingenerate/0` constructs exactly 128 bits, which matches `encode/1`’s raw-binary clause. The inferred `:error` comes from `encode/1`’s catch-all, which this caller cannot reach. The return type’s fixed-size binary approximation also prevents an established proof. |

The three direct witnesses, including controls for both `page_opts/1` input
alternatives, are executable with:

```sh
elixir bench/corpus/holdout_witnesses.exs /tmp/spec-lint-expansion
```

They load the pinned Ash BEAM without starting its application. The remaining
source-only reports are checked by a script that builds a minimal Ash domain
with private, in-memory ETS resources from the pinned build. It records for
every witness and control input whether it satisfies the cited `@spec`, and
counts a report as witnessed only when the witness input does:

```sh
elixir bench/corpus/ash_integration_witnesses.exs /tmp/spec-lint-expansion
```

It loads `_build/test/lib/*/ebin` of the pinned checkout, starts only
`telemetry`, `decimal`, `jason`, `spark`, `ecto`, `ets`, `splode` and `ash`
(plus `Mix.start/0`, which Ash's resource verifier reads), needs no network or
disk, and raises if a pinned observation or verdict changes. Its predicates for
“inside the declared domain” and “inside the declared return” are hand-written
from the spec text and do not call SpecLint; the domain predicates check the
struct fields whose declared types are not functions, filters or nested Ash
structs. Outcome: five reports witnessed with in-domain inputs (`read/2`,
`read_one/2`, `read_first/2`, `page/2`, `Policy.solve/1`), `data_layer_query/2`
refuted with an in-domain query, and `Query.apply_to/3` probable: its escape was
observed only for a query outside `Ash.Query.t()`.

## Silent function sample

The sampling frame is distinct MFAs with `obligation == "unknown"` in the
ledger. For Ash, exclude generated `.Opts.`/`Opts.` validators, `.Igniter.`
helpers, and `.Test.` functions; sort the remaining 435 MFAs and sample four
with Python `random.Random(20260929).sample`. For Nx, sort all seven unknown
MFAs and sample four using the same seed. This rule was fixed before reading
the selected source. Every selected slice was `top_only` in the report.

| Sampled MFA | Source review |
| --- | --- |
| `Ash.Query.ensure_selected/2` | `ash/lib/ash/query/query.ex:1853-1867`: returns the query after selected fields are added; no visible return omission. The inferred result is top-only despite an exact `t()` return shape in the spec. |
| `Ash.Resource.Info.attribute_names/1` | `ash/lib/ash/resource/info.ex:715-718`: delegated persisted DSL lookup; cannot establish `MapSet.t()` without the resource metadata contract. |
| `Ash.Type.get_type/1` | `ash/lib/ash/type/type.ex:689-706`: within the declared atom/module/array domain, branches return the input or a registered type; no visible omission. The catch-all accepts wider runtime inputs outside the spec domain. |
| `Ash.Generator.many_queries/5` | `ash/lib/ash/generator/generator.ex:946-954`: delegates to `many_changesets/5`; the result shape depends on that helper and is not resolved by stored inference. |
| `Nx.load_numpy_archive!/1` | `nx/nx/lib/nx.ex:16387-16412`: returns a mapped list on successful unzip and raises on failure; no visible normal-return omission. |
| `Nx.standard_deviation/2` | `nx/nx/lib/nx.ex:16567-16571`: returns `sqrt(variance(...))`; no visible normal-return omission, though inference is top-only across the calls. |
| `Nx.load_numpy!/1` | `nx/nx/lib/nx.ex:16235-16247`: valid NumPy input delegates to parser; invalid input raises. Parser return precision is unavailable here. |
| `Nx.vectorize/2` | `nx/nx/lib/nx.ex:5338-5410`: multiple clauses and delegated tensor/container transforms; no omission established by this sample. |

The sample checks silence, not overall false-negative rate. It did not find a
new omission; eight of the 12 Ash reports are now witnessed at runtime (three
direct, five integration), `Ash.Query.apply_to/3` is probable, and
`Ash.data_layer_query/2`, `Ash.Resource.Info.sortable?/3` and the structured
UUID candidate are refuted.
