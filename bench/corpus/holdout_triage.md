# Ash and Nx holdout triage

This review uses the pinned revisions in `expansion.json`: Ash
`164a4c0d0ef7724c5fd2153876c2cf90cd938863` and Nx
`a0076029fe98f851c0183e2fb47d58de3d4bcb34`. The inputs are
`reports/expansion/{ash,nx}.spec_lint.json`. Ash completed with 990 compared
functions, 992 compared slices, 12 informational findings, and no CI gate.
Nx completed with 7 compared functions, 9 compared slices, and no findings.
No classifier or compiler behavior was changed after opening these holdouts.

“Confirmed” below means the source supplies a path for an input allowed by the
spec to return an undeclared value. “Probable” needs an end-to-end witness for
reachability. “Refuted” means the inferred alternative comes from a wider
callee or path than the caller can take. All 12 emitted findings are non-gating
under the current policy, regardless of this human judgment.

| Finding | Judgment | Source and reason |
| --- | --- | --- |
| `Ash.page/2` SL002 domain escape | **Confirmed** | `ash/lib/ash.ex:2204-2232,2270-2328`: the spec allows integer requests on a `Keyset` page, yet that clause returns `{:error, binary()}`; `Ash.Error.t()` is an exception type. The paths delegating to `read/2` can also relay its third query element. The direct `Keyset` branch is enough to establish the return omission; a runtime page with fully valid `Ash.Page.Keyset.t()` fields was not constructed here. |
| `Ash.load/3` SL002 domain escape | **Confirmed, witnessed** | `ash/lib/ash.ex:2446-2454`: `:ok` is an allowed first input and the clause returns `{:ok, :ok}`. The declared successful payload is a resource record, list of records, or nil; `Ash.Resource.record()` is `struct()` (`ash/lib/ash/resource.ex:13`). |
| `Ash.data_layer_query/2` SL002 domain escape | **Unconfirmed; likely inference spillover** | `ash/lib/ash.ex:2660-2664` calls `read/2` with `data_layer_query?: true`. Its inferred extra is a three-tuple. `ash/lib/ash/actions/read/read.ex:415-425,1040-1060,1160-1178` takes a dedicated query-building branch and appears to return two-tuples. A validated resource/query with `return_query?: true` is needed to establish whether this branch can ever return three elements. |
| `Ash.read/2` SL002 domain escape | **Confirmed from source** | `ash/lib/ash.ex:108-117,2761-2794`: `return_query?: true` is a documented valid option. The `{:ok, results, query}` case returns a three-tuple even though the spec lists only two-tuples. `ash/lib/ash/actions/read/read.ex:2819-2825` constructs that form. |
| `Ash.read_one/2` SL002 domain escape | **Confirmed from source** | `ash/lib/ash.ex:163-174,2912-2934`: the valid `return_query?` option passes through the read-one schema, and the function explicitly returns `{:ok, result, query}`. `ash/lib/ash/helpers.ex:318-325` preserves the third element. |
| `Ash.read_first/2` SL002 domain escape | **Confirmed from source** | `ash/lib/ash.ex:2991-3012` uses the same read-one options and `do_read_one/3`; its `{:ok, result, query}` case also returns an undeclared third element. |
| `Ash.Page.page_opts/1` SL001 clause conflict | **Confirmed, witnessed** | `ash/lib/ash/page/page.ex:11-20`: both `false` and `nil` are explicitly in the input spec, but their clause returns `{:ok, false}` and `{:ok, nil}` rather than `{:ok, page()}`. The finding does not gate because whole-slice translation records arrow polarity loss even though this particular clause is literal and contained. This is a useful case for future per-clause qualification. |
| `Ash.Policy.Policy.solve/1` SL002 domain escape | **Probable true** | `ash/lib/ash/policy/policy.ex:75-98` returns `{:error, authorizer, :unsatisfiable}` when the solver yields no scenarios; the spec requires an `Ash.Error.t()` third element. The specific `Authorizer.t()` input that reaches an unsatisfiable scenario has not been built. |
| `Ash.Query.apply_to/3` SL002 domain escape | **Probable true** | `ash/lib/ash/query/query.ex:4346-4373` has an `else {:error, error} -> {:error, Ash.Error.to_ash_error(error)}` branch, while its spec promises only `{:ok, records}`. Reachability with a valid query, resource, and records needs a controlled witness. |
| `Ash.Resource.Info.sortable?/3` SL002 domain escape | **Refuted** | `ash/lib/ash/resource/info.ex:911-965`: the case clauses return `true` or `false`, including its default. No path returning the inferred `nil` was found. This is propagated call imprecision, not a demonstrated missing alternative. |
| `Ash.Test.refute_has_error/3` SL002 domain escape | **Confirmed, witnessed** | `ash/lib/ash/test.ex:109-122`: the spec allows `:ok` input but the first clause returns `:ok`, outside `Ash.Error.t() | no_return()`. Passing `Ash.Error.Invalid` as the deprecated class argument keeps the witness inside the declared domain. |
| `Ash.UUIDv7.generate/0` SL002 structured possible | **Refuted** | `ash/lib/ash/uuid_v7.ex:49-76,95-122`: `bingenerate/0` constructs exactly 128 bits, which matches `encode/1`’s raw-binary clause. The inferred `:error` comes from `encode/1`’s catch-all, which this caller cannot reach. The return type’s fixed-size binary approximation also prevents an established proof. |

The three direct witnesses, including controls for both `page_opts/1` input
alternatives, are executable with:

```sh
elixir bench/corpus/holdout_witnesses.exs /tmp/spec-lint-expansion
```

They load the pinned Ash BEAM without starting its application. The `page/2`,
`read*/2`, policy, and query judgments above rely on the specified source
branches and do not claim a separate integration witness.

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
new omission; three of the 12 Ash reports are direct counterexamples and four
more have clear source paths, while the structured UUID candidate is refuted.
