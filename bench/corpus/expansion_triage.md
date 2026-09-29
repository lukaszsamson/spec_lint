# Expansion cohort source triage

Sources are the isolated copies pinned by `expansion.json`:

| Project | Revision |
| --- | --- |
| Req | `c6e8ab1f9d1c8e1aef935a6319faa40487bb6f42` |
| Oban | `23fa8176b3586ca84f5859793739fad798e69d2b` |

Run `elixir bench/corpus/expansion_witnesses.exs /tmp/spec-lint-expansion` after compiling the pinned Req and Oban copies. The script loads their BEAM paths without starting the applications. It calls only the named pure functions and checks literal values against the relevant parts of the original type declarations; it does not use SpecLint's translator or classifier.

## Req: broad constructor input permits an out-of-type result

`Req.Response.new/1` declares `keyword() | map() | struct()` as input and `Req.Response.t()` as output (`req/lib/req/response.ex`, lines 54–76). `t()` requires `status: non_neg_integer()` (lines 23–29). The constructor copies the `:status` key without validation. The executable witness `Req.Response.new(%{status: -1})` returned `%Req.Response{status: -1}`. `%{status: 200}` is the paired in-domain control and returned an in-type struct.

This is a type-contract counterexample under the written `map()` input domain. A negative HTTP status is not a sensible request or response value, so a lint warning here might be considered noise by the library author. The tool should explain both the broad declared input and the observed return, and this case should be separated from omissions found with ordinary library inputs. Whether it is a useful default CI warning needs review.

## Oban: a gated return omission with valid inputs

`Oban.Registry.via/3` declares `name()`, `role()` and `value()` inputs; each includes the witness `(Oban, nil, :witness)` (`oban/lib/oban/registry.ex`, lines 6–8 and 122–128; `oban/lib/oban.ex`, line 26). The return spec promises `{:via, Registry, {Oban.Registry, key()}}`, whose inner tuple has two elements. The non-`nil` branch returns `{:via, Registry, {Oban.Registry, key, value}}`, whose inner tuple has three. The pure witness returned `{:via, Registry, {Oban.Registry, Oban, :witness}}`. With the same `name` and `role` and a `nil` value, the control returned `{:via, Registry, {Oban.Registry, Oban}}`.

The expansion report's gated `SL001 clause_conflict` is this function. Source and direct execution support it as a true positive; there is no outside-domain input or author intent caveat as with the Req constructor.

## Oban: runtime accepted input lies outside the declared input type

`Oban.Period.t()` is `pos_integer() | {pos_integer(), time_unit()}` (`oban/lib/oban/period.ex`, line 41), and `to_seconds/1` declares a positive integer return (line 84). Its `is_seconds` runtime guard accepts zero (line 59), so `to_seconds(0)` returns zero (line 90). Since zero is outside the spec's input domain, that execution does not prove a missing return type. The paired `to_seconds(1)` control is inside both domains.

This is evidence of a possible missing **input** in `Period.t()` or of a deliberate runtime tolerance beyond the documented type. It is a negative control for any return-mismatch rule that widens `pos_integer()` to `integer()` and then mistakes zero for an in-domain return. It also illustrates why preserving the refinement's lower bound matters.

## Signature report triage

The completed signature reports are `reports/expansion/req.spec_lint.json` and `reports/expansion/oban.spec_lint.json`. Req compared 87 slices, with no findings and 75 unknown obligations (36 `top_only`, 39 `no_counted_component`). Oban compared 130, with two findings and 115 unknown obligations (93 `top_only`, 17 `no_counted_component`, five `near_top`). Both reports say `complete` and have zero unavailable or unsupported slices. These counts describe analysis coverage, not spec correctness.

All reported findings were reviewed:

| Project and finding | Source judgment |
| --- | --- |
| Oban `SL001 clause_conflict` on `Oban.Registry.via/3`, gated | True return omission. The non-`nil` branch adds a third element to the inner tuple, demonstrated above with an input inside the declared domain. |
| Oban `SL002 possible_domain_escape` on `Oban.Period.to_seconds/1`, informational | False candidate for a missing return within the declared input domain. The tuple branches do not guard `value`: `to_seconds({1.5, :minute})` actually returns `90.0`, but that input is outside `Period.t()`. Likewise zero input is outside the positive-integer spec. The float is therefore a valid implementation-wide inference alternative, not evidence of a compiler arithmetic bug. |

There are no Req findings, including none for the constructor counterexample above. Its output is a struct with one invalid field, and the signature analysis does not establish that field value for the broad input map.

For a reproducible check of unknowns, sort the rows with `obligation == "unknown"` by `(mfa, slice, unknown_reason, translation)`, draw eight with Python `random.Random(20260929).sample(rows, 8)`, then sort the drawn rows for display. The sample is fixed before manual source review:

| Req sampled unknown | Report reason | Source interpretation |
| --- | --- | --- |
| `Req.Request.put_option/3` | `no_counted_component` | `request.ex:519–523`: validates a key, then updates and returns the request struct. Struct shape is present, but not a counted return alternative. |
| `Req.Response.update_private/4` | `no_counted_component` | `response.ex:182–185`: updates a private map field through a callback and returns the struct. |
| `Req.Test.Ownership.start_link/1` | `top_only` | `test/ownership.ex:33–39`: delegates to `GenServer.start_link`; the external call supplies the return. |
| `Req.Test.transport_error/2` | `no_counted_component` | `test.ex:415–446`: conditionally compiled Plug branch updates a connection struct; the alternative branch is only compiled without Plug. |
| `Req.assign/2` | `no_counted_component` | `req.ex:1431–1435`: updates `assigns` on a request or response struct. |
| `Req.delete/2` | `top_only` | `req.ex:1068–1071`: delegates to `request/1`; no local return alternative. |
| `Req.head!/2` | `top_only` | `req.ex:780–782`: delegates to `request!/1`. |
| `Req.post/2` | `top_only` | `req.ex:828–831`: delegates to `request/1`. |

| Oban sampled unknown | Report reason | Source interpretation |
| --- | --- | --- |
| `Oban.Midwife.start_queue/2` | `top_only` | `midwife.ex:20–42`: delegates to `DynamicSupervisor.start_child/2`; one clause normalizes tuple input. |
| `Oban.Plugins.Reindexer.child_spec/1` | `top_only` | `plugins/reindexer.ex:67–68`: calls `super/1`; inherited implementation is the return source. |
| `Oban.Queue.Executor.record_unsaved/1` | `top_only` | `queue/executor.ex:304–311`: `put_in` on a nested job field or returns the executor unchanged. No source witness of a return outside `t()`. |
| `Oban.Queue.Producer.shutdown/1` | `top_only` | `queue/producer.ex:34–36`: `GenServer.call/2` determines the return. |
| `Oban.Queue.Watchman.child_spec/1` | `no_counted_component` | `queue/watchman.ex:11–15`: constructs a supervisor child-spec map; likely a shape the current counter does not treat as an alternative. |
| `Oban.Telemetry.attach_default_logger/1` | `top_only` | `telemetry.ex:432–469`: delegates to `:telemetry.attach_many/4` after building options. |
| `Oban.Validation.validate_schema/2` | `top_only` | `validation.ex:32–46`: `Enum.reduce_while/3` hides the `:ok` / `{:error, reason}` alternatives. |
| `Oban.delete_job/2` | `top_only` | `oban.ex:1510–1518`: delegates to `Engine.delete_job/2` after resolving config. |

This sample points to delegated calls, higher-order traversal and struct/map returns as different reasons for unknown results. It does not establish that those specs are correct. Ash and Nx remain untouched holdouts.
