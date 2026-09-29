# Frozen evaluation inventory, version 2

Version 1 was frozen on 2026-09-29 at tool revision `62862e9` (commit
`e464905`), before any Milestone 5 measurement (NEXT_STEPS.md, M5, "First
task"). Version 2 (2026-09-29, tool revision `0cd5d11`) is the change the
Milestone 5 review required; it is described in "Changes in version 2"
below. Every later recall or precision number cites the version it was
computed against; the release campaign 1 figures are given under both
(`bench/corpus/reports/release-1/detection_v1.json` and
`detection_v2.json`). Changing a family, a status, a witness, the family
rule, the denominator or the holdout procedure is a new version of this
file and of `inventory.json`, in its own commit, with the change described
here.

## Changes in version 2

1. **C01 promoted to witnessed family F18** (`Ash.Query.apply_to/3`,
   `return_value`). Version 1 counted it as source-only because the only
   observed `{:error, _}` came from a query that loads a calculation, which
   is outside `Ash.Query.t()` (`calculations: %{optional(atom) => :wat}`).
   The review found in-domain error paths: `t()` declares `filter:
   Ash.Filter.t() | nil` and `Ash.Filter.t :: %Ash.Filter{}`, so any filter
   keeps a query inside `t()`, and a filter that casts the string title to
   an integer (`type(title, :integer) == 1`) or an `error/2` expression
   makes `Ash.Filter.Runtime.filter_matches/4` fail, and `apply_to/3`
   returns its `{:error, Ash.Error.to_ash_error(error)}` branch
   (`query.ex:4366-4368`), outside the declared `{:ok,
   list(Ash.Resource.record())}`. Both are now witnesses in
   `ash_integration_witnesses.exs`, with a control (`title == "first"`,
   `{:ok, [record]}`). **Denominator 17 -> 18** (`return_value` 14 -> 15).
2. **Holdout witnesses carry their own domain check.** Version 1 cited
   case ids (`page_opts(false)`, `load(:ok, nil)`, ...) that
   `holdout_witnesses.json` did not contain, and that record had no
   in-domain flag (for F10 as well as F11 and F12, although version 1 named
   only F11 and F12). `holdout_witnesses.exs` now gives each observation a
   stable case id (`ash_page_opts_false`, `ash_page_opts_nil`,
   `ash_load_ok`, `ash_refute_has_error_ok`), and decides
   `input_in_declared_domain` and `outside_declared_return` with
   hand-written predicates over the cited types (`page()`, `load_statement()`,
   `Ash.Error.class_module()`, `Ash.Error.t()`); it calls `Ash.load(:ok,
   nil, [])` explicitly (version 1 called `load/2` through the default), and
   F11 gains a control (`Ash.load(nil, nil, [])`, `{:ok, nil}`). The
   verdicts are unchanged.
3. `ash_integration_witnesses.exs`: every observation has a `case` id (the
   MFA, or the MFA and a description where one MFA has several), and
   `Support.query_t?/1` also checks `filter` and `action` by their struct.
   The seven version-1 observations are unchanged.
4. F11's source citation: the `load(:ok, _, _)` clause is line 2454 (2451
   is the function head).
5. `detection.exs` refuses a report whose provenance revision is not the
   inventory pin, and lists every counted finding per family (`matched`,
   with its fingerprint and its inferred extra or stored clause), so each
   match can be audited. The counting rule itself is unchanged.

| File | What it is |
| --- | --- |
| `inventory.json` | the machine-readable inventory: definitions, corpora and pins, families, candidates not counted, holdout procedure |
| `pinned_witnesses.exs`, `pinned_witnesses.json` | runtime witnesses on the pinned library builds for the nine original omissions, `Ecto.Changeset.apply_changes/1` and `Absinthe.Blueprint.Input.parse/1` (new with this inventory; before it these had stand-in witnesses only or a witness in prose) |
| `detection.exs` | computes gated, reported and silent per family from committed product reports |
| `detection_v1.json` | its output on the committed reports at the version 1 freeze (pre-release report sets) |
| `../corpus/reports/release-1/detection_v1.json`, `detection_v2.json` | its output on the release campaign 1 reports under versions 1 and 2 (section "Current detection") |

The other witnesses are the existing scripts and their committed outputs:
`bench/corpus/expansion_witnesses.exs` (`reports/expansion/witnesses.json`),
`bench/corpus/holdout_witnesses.exs` (`reports/expansion/holdout_witnesses.json`)
and `bench/corpus/ash_integration_witnesses.exs`
(`reports/expansion/ash_integration_witnesses.json`). For version 2 the
holdout and Ash integration scripts were changed and their records
regenerated against the pinned checkouts (the version-1 observations are
unchanged); `pinned_witnesses.exs` and `expansion_witnesses.exs` were rerun
and reproduced their committed records. `test/spec_lint/evaluation_inventory_test.exs`
checks that every witness reference resolves to exactly one in-domain
observation outside the declared return in its record.

## Definitions

**Omission.** An MFA whose `@spec` return leaves out a value that a runtime
call returns normally, with arguments inside the declared argument types.

**Status.**

- *witnessed*: a committed, executable witness calls the MFA on the pinned
  library build (not a stand-in) with arguments inside the declared domain,
  checked against the cited type declarations, and the result is outside
  the declared return. Struct arguments are checked field by field; a
  default field outside its declared type is repaired first (as in
  `ash_integration_witnesses.exs`, and here `Plug.Conn`'s `remote_ip: nil`).
- *source-only*: a source path to an undeclared return is plausible, but no
  in-domain runtime witness exists.
- *refuted*: an in-domain witness returned inside the declared return, or
  source review shows the alternative is unreachable for in-domain inputs.

**Family rule (the counting unit is the omission family).**

1. All omitted alternatives of one MFA are one family, whatever the number
   of clauses, slices, inputs or findings. The seven
   `Absinthe.Blueprint.Input.parse/1` clause gates are one family.
2. Two MFAs are one family when the undeclared value that witnesses one is
   produced by the same source construct as the other's: one returns the
   other's result (delegation), or both relay a value built at one origin.
   The relation is closed transitively.
3. MFAs with separate code are separate families, even when the defect is
   of the same kind (two stale specs are two families).

Consequences against earlier counts: the "nine real omissions" are **eight
families** (`Decimal.cmp/2` delegates to `Decimal.compare/2`);
`Ecto.Changeset.apply_changes/1`, the omission found by the body backend
experiment, joins `apply_action/2`'s family (which returns it inside
`{:ok, _}`); `Ash.read/2`, `read_one/2` and `read_first/2` are one family
(each relays the `return_query?` three-tuple built by
`Ash.Actions.Read.add_query/3`).

**Categories.** They tag families and change no rule policy.
`struct_default` and `struct_field_from_input` families stay in the
denominator, and every recall figure is also given for `return_value` alone.

- `return_value`: the returned value, or a component that is not a struct
  field, is outside the declared return.
- `struct_default`: a returned struct keeps a field at its default value,
  outside the field's declared type.
- `struct_field_from_input`: a returned struct field holds a value copied
  from an in-domain argument, outside the field's declared type.

## Counting

- **Denominator**: the number of families with status *witnessed*: **18**
  (15 `return_value`, 1 `struct_default`, 2 `struct_field_from_input`;
  version 1: 17 and 14).
- **Gated**: at least one MFA of the family has a finding with rule `SL001`
  and `gate: true` in the product report of the family's corpus under the
  measured adapter.
- **Reported**: not gated, and at least one MFA of the family has any
  finding (`SL001` with `gate: false`, or `SL002`).
- **Silent**: no finding on any MFA of the family.
- **Gated recall** = gated / 18. **Reported recall** = (gated + reported) /
  18. Both are also given over the 15 `return_value` families.
- A finding counts by its subject MFA, whatever its slice or clause. The
  reports are the committed product reports (`*.spec_lint.json`, default
  configuration, with a provenance revision equal to the pin); a
  measurement names the report set and its file hashes (`detection.exs`
  records them) and lists each counted finding. The rule would let an
  unrelated finding on a family's MFA count as a detection; none does in
  release campaign 1: the inferred extra (SL002) or the stored clause
  (SL001) of every counted finding contains the family's witnessed value
  (`matched` in `detection_v2.json`). A future version may require that
  match.
- Source-only and refuted candidates are outside the denominator. A finding
  on a refuted candidate is a false positive for precision, not a detection.

## Witnessed families

Revisions are the full pins in `inventory.json` (decimal `92a28e6`, plug
`73404f8`, ecto `94d6927` in `bench/corpus/run.sh`; oban `23fa817`, req
`c6e8ab1`, ash `164a4c0`, absinthe `1372ceb` in `bench/corpus/expansion.json`
and `bench/corpus/README.md`). Witness scripts: **P** =
`bench/evaluation/pinned_witnesses.exs`, **E** = `expansion_witnesses.exs`,
**H** = `holdout_witnesses.exs`, **A** = `ash_integration_witnesses.exs`.
Each row's control, where one exists, is in `inventory.json`.

| Family | Corpus | MFA(s) | Cat. | Witness input (inside the declared domain) | Observed | Declared return |
| --- | --- | --- | --- | --- | --- | --- |
| F01 decimal-compare-nan | decimal | `Decimal.compare/2`, `Decimal.cmp/2` | rv | P: `compare(Decimal.new("NaN"), Decimal.new(1))` and `cmp(...)`, traps `[]` | `Decimal.new("NaN")` | `:lt \| :gt \| :eq` |
| F02 plug-query-decode-initial | plug | `Plug.Conn.Query.decode/4` | rv | P: `decode("", [unexpected: 1], Plug.Conn.InvalidQueryError, true)` | `%{unexpected: 1}` | `%{optional(String.t()) => term()}` |
| F03 plug-merge-private-keys | plug | `Plug.Conn.merge_private/2` | sfi | P: `merge_private(%Plug.Conn{remote_ip: {127, 0, 0, 1}}, [{"unexpected", 1}])` | `private: %{"unexpected" => 1}` | `Plug.Conn.t()` (`private: %{optional(atom) => any}`) |
| F04 ecto-changeset-nil-data | ecto | `Ecto.Changeset.apply_action/2`, `apply_changes/1` | rv | P: `apply_action(%Ecto.Changeset{valid?: true}, :insert)`; `apply_changes(%Ecto.Changeset{})` | `{:ok, nil}`; `nil` | `{:ok, Ecto.Schema.t() \| map()} \| {:error, t}`; `Ecto.Schema.t() \| map()` |
| F05 ecto-join-escape-stale | ecto | `Ecto.Query.Builder.Join.escape/3` | rv | P: `escape(quote(do: x in fragment("foo")), [], __ENV__)` | a 5-tuple | a 4-tuple |
| F06 ecto-quoted-type-stale | ecto | `Ecto.Query.Builder.quoted_type/2` | rv | P: `quoted_type(:example, [])` | `:atom` | `Ecto.Type.primitive() \| {non_neg_integer, atom \| Macro.t()}` |
| F07 ecto-assoc-query-rows | ecto | `Ecto.Repo.Assoc.query/4` | rv | P: `query([[1]], [], {}, fn row -> row end)` | `[[1]]` | `[Ecto.Schema.t()]` |
| F08 ecto-preloader-query-fun | ecto | `Ecto.Repo.Preloader.query/7` | rv | P: `query([[1]], MyRepo, [], nil, [], fn _ -> :unexpected end, {%{}, []})` | `[:unexpected]` | `[list]` |
| F09 oban-registry-via-value | oban | `Oban.Registry.via/3` | rv | E: `via(Oban, nil, :witness)` | `{:via, Registry, {Oban.Registry, Oban, :witness}}` | `{:via, Registry, {Oban.Registry, key()}}` |
| F10 ash-page-opts-falsy | ash | `Ash.Page.page_opts/1` | rv | H: `page_opts(false)`, `page_opts(nil)` | `{:ok, false}`, `{:ok, nil}` | `{:ok, page()} \| {:error, String.t()}` |
| F11 ash-load-ok | ash | `Ash.load/3` | rv | H: `load(:ok, nil, [])` | `{:ok, :ok}` | `{:ok, record \| [record] \| nil} \| {:error, term}` |
| F12 ash-refute-has-error-ok | ash | `Ash.Test.refute_has_error/3` | rv | H: `refute_has_error(:ok, Ash.Error.Invalid, fn _ -> false end)` | `:ok` | `Ash.Error.t() \| no_return()` |
| F13 ash-read-return-query | ash | `Ash.read/2`, `Ash.read_one/2`, `Ash.read_first/2` | rv | A: each with `return_query?: true` on an ETS resource | `{:ok, result(s), %Ash.Query{}}` | two-tuples only |
| F14 ash-page-keyset-integer | ash | `Ash.page/2` | rv | A: a repaired in-domain keyset page, request `3` | `{:error, "Cannot seek to a specific page ..."}` | `{:ok, page()} \| {:error, Ash.Error.t()}` |
| F15 ash-policy-solve-unsatisfiable | ash | `Ash.Policy.Policy.solve/1` | rv | A: a repaired in-domain authorizer, two conflicting `:unknown` checks | `{:error, %Authorizer{}, :unsatisfiable}` | third element `Ash.Error.t()` |
| F16 absinthe-input-parse-source-location | absinthe | `Absinthe.Blueprint.Input.parse/1` | sd | P: `parse/1` of `1`, `1.0`, `nil`, `"s"`, `true`, `[]`, `%{}` (clauses 1 to 7) | `Input.*` structs with `source_location: nil` | `nil \| Input.t()` (`source_location: SourceLocation.t()`) |
| F17 req-response-new-status | req | `Req.Response.new/1` | sfi | E: `new(%{status: -1})` | `%Req.Response{status: -1}` | `Req.Response.t()` (`status: non_neg_integer()`) |
| F18 ash-query-apply-to-error (v2) | ash | `Ash.Query.apply_to/3` | rv | A: an in-domain query (`distinct: []`) filtered by `type(title, :integer) == 1`, or by an `error/2` expression, with records read from the resource | `{:error, %Ash.Error.Unknown.UnknownError{}}`, `{:error, %Ash.Error.Query.InvalidFilterValue{}}` | `{:ok, list(Ash.Resource.record())}` |

Cat.: rv `return_value`, sd `struct_default`, sfi `struct_field_from_input`.

Notes that do not change a status:

- F05, F10 and F12 have no in-domain control inside the declared return:
  every clause of `Join.escape/3` returns a 5-tuple, `page_opts/1`'s
  catch-all returns `{:ok, keyword()}`, and `refute_has_error/3` returns
  `:ok`, `nil` or raises.
- F10 to F12: version 1's `holdout_witnesses.json` recorded no in-domain
  flag and its domain check was by hand; version 2's record carries the
  flag, decided by predicates over the same declarations: `false` and
  `nil` are explicit alternatives of `page_opts/1`'s argument; `:ok` is an
  explicit first argument alternative of both other specs; `nil` is in
  `load_statement()` through `atom` (`lib/ash.ex:36-41`);
  `Ash.Error.Invalid` is in `Ash.Error.class_module()` (`use Splode,
  error_classes: [...]`); a 1-ary fun is in `(Ash.Error.t() -> boolean)`.
- F10 is a `@doc false` validator, F12 a test helper, F15 an internal
  solver boundary: real omissions of less user-facing functions.
- The stand-ins of F01 to F08 (`SpecLint.OmissionFixtures.Cases`) and of F09
  and F10 (`ClauseLocal`) stay in `test/spec_lint/omissions_test.exs`; they
  pin classes, they are not the witnesses counted here.

## Candidates not counted

| Id | MFA | Status | Why |
| --- | --- | --- | --- |
| C01 | `Ash.Query.apply_to/3` | promoted to F18 in version 2 | version 1: the `{:error, _}` escape was observed only for a query loading a calculation, outside `Ash.Query.t()`; version 2 witnesses two in-domain filters |
| R01 | `Ash.data_layer_query/2` | refuted | an in-domain witness with `return_query?: true` returned `{:ok, %{...}}`, inside the declared return |
| R02 | `Ash.Resource.Info.sortable?/3` | refuted | source: every path returns `true` or `false` |
| R03 | `Ash.UUIDv7.generate/0` | refuted | source: `encode/1`'s `:error` catch-all is unreachable from this caller |
| R04 | `Oban.Period.to_seconds/1` | refuted | the zero and float returns need inputs outside `Period.t()` (`input_in_declared_domain: false`) |

Not candidates, and so outside this inventory:

- the three untriaged SL002 reports of the fresh holdouts
  (`Absinthe.Phase.Init.run/2`, `Absinthe.Subscription.PipelineSerializer.pack/1`,
  `Tesla.Adapter.Mint.read_chunk/3`, `bench/corpus/holdout2_baseline.md`).
  Triaging one into a witnessed family is a new inventory version;
- the SL002 false positives of the original corpora (EXPERIMENTS.md) and
  the stdlib SL002 reports, which are precision records, not omission
  candidates;
- synthetic fixtures (`test/support/`, the clause-local review probes,
  `bench/helper_experiment/`), which are not library code.

## Audit of the "six witnessed Ash misses"

The claim was checked against `holdout_triage.md`,
`reports/expansion/holdout_witnesses.json` and
`reports/expansion/ash_integration_witnesses.json`, all rerun for this
inventory. Ash has 12 reports (11 SL002, 1 SL001).

**Qualify** (a runtime witness inside the declared domain): 9 MFAs in 7
families: `page_opts/1` (F10), `load/3` (F11), `refute_has_error/3` (F12),
`read/2`, `read_one/2`, `read_first/2` (F13), `page/2` (F14),
`Policy.solve/1` (F15) and, from version 2, `Query.apply_to/3` (F18).

**Do not qualify** (3; version 1 listed 4, with `Query.apply_to/3`, whose
only witness then was outside `Ash.Query.t()`):

- `Ash.data_layer_query/2`: refuted by an in-domain witness.
- `Ash.Resource.Info.sortable?/3`, `Ash.UUIDv7.generate/0`: refuted by
  source review; no witness.

**Misses.** `page_opts/1` gates under the current default
(`clause_local_qualification`), so it is not a miss. The witnessed Ash
misses are **8 MFAs in 6 families** (F11 to F15 and F18), all reported as
SL002, none gated (version 1: 7 MFAs in 5 families). The claim "six"
matched neither version-1 count: six was the number of witnessed Ash
*families* including the gated `page_opts/1`. Ash contributes **7**
witnessed families to the denominator, 1 gated and 6 reported (version 1:
6, 1 and 5). Every qualifying record now carries its in-domain flag.

## Current detection

Computed by `detection.exs` from committed product reports only, with every
report's sha256, provenance revision and counted findings in the output.

**Release campaign 1** (`bench/corpus/reports/release-1/`, tool `06b7496`,
all three adapters): `detection_v2.json` (this version) and
`detection_v1.json` (version 1, the same reports). The classes are the same
for the three adapters.

| Family | release-1, all three adapters |
| --- | --- |
| F01 decimal-compare-nan | silent |
| F02 plug-query-decode-initial | silent |
| F03 plug-merge-private-keys | silent |
| F04 ecto-changeset-nil-data | silent |
| F05 ecto-join-escape-stale | reported (SL002 `possible_domain_escape`) |
| F06 ecto-quoted-type-stale | reported (SL002 `possible_domain_escape`) |
| F07 ecto-assoc-query-rows | silent |
| F08 ecto-preloader-query-fun | silent |
| F09 oban-registry-via-value | **gated** (SL001 `clause_conflict`) |
| F10 ash-page-opts-falsy | **gated** (SL001 `clause_conflict`) |
| F11 ash-load-ok | reported (SL002) |
| F12 ash-refute-has-error-ok | reported (SL002) |
| F13 ash-read-return-query | reported (SL002 on all three MFAs) |
| F14 ash-page-keyset-integer | reported (SL002) |
| F15 ash-policy-solve-unsatisfiable | reported (SL002) |
| F16 absinthe-input-parse-source-location | **gated** (7 SL001 `clause_conflict`) |
| F17 req-response-new-status | silent |
| F18 ash-query-apply-to-error | reported (SL002 `possible_domain_escape`, inferred extra `{:error, term()}`) |

| Inventory | Adapter | Gated | Reported (not gated) | Silent | Gated recall | Reported recall | `return_value` only: gated / reported recall |
| --- | --- | ---: | ---: | ---: | --- | --- | --- |
| v2 | 1.21 `c24c235` | 3 | 8 | 7 | 3/18 | 11/18 | 2/15, 10/15 |
| v2 | 1.21 `648b2a9` | 3 | 8 | 7 | 3/18 | 11/18 | 2/15, 10/15 |
| v2 | 1.20.4 | 3 | 8 | 7 | 3/18 | 11/18 | 2/15, 10/15 |
| v1 | each of the three | 3 | 7 | 7 | 3/17 | 10/17 | 2/14, 9/14 |

By category (v2, all adapters): `return_value` 2 gated, 8 reported, 5
silent; `struct_default` 1 gated (F16); `struct_field_from_input` 2 silent
(F03, F17). Of the eight original families (F01 to F08) none is gated and
two are reported, as before (0 of 9 and 2 of 9 by MFA).

**At the version 1 freeze** (`detection_v1.json` in this directory): 1.21
at `c24c235` from `reports/elixir-1.20.4/c24c235/` (tool `f364fa1`);
`reports/m1_review/` (tool `e4fc0c7` with uncommitted changes) and
`reports/upstream-648b2a9/` (tool `63618c2` with uncommitted changes) gave
the identical classification of every family, and so did 1.20.4
(`reports/elixir-1.20.4/`, tool `f364fa1`): 3 / 7 / 7 of 17, the same
classes as release campaign 1 under version 1.

## Holdout selection for precision experiments

A precision experiment changes a gating prerequisite or an evidence class.
Its holdouts must be able to show an effect, so the criterion is fixed:
**a project qualifies when the product report of its baseline run** (the
tool revision before the experiment, default configuration,
`SPEC_LINT_PRODUCT_ONLY=1`) **is complete and contains at least one SL001
finding with `gate: false` and at least one prerequisite `blocked`.** Only
this count is read before the experiment is frozen:

```sh
jq '[.findings[] | select(.rule == "SL001" and .gate == false
      and any(.prerequisites[]; .[1] == "blocked"))] | length' REPORT
```

No current corpus qualifies: all nine SL001 findings of the fifteen gate
under both adapters.

**Candidates** (33, none among the fifteen corpora): bandit, cachex,
commanded, credo, db_connection, earmark_parser, ecto_sql, ex_aws, ex_doc,
ex_machina, explorer, finch, floki, gettext, httpoison, joken,
membrane_core, mint, nimble_csv, nimble_parsec, nimble_pool, phoenix,
phoenix_html, phoenix_pubsub, postgrex, reactor, redix, spark, stream_data,
swoosh, telemetry_metrics, thousand_island, timex.

**Draw order**, from the sorted list shuffled by Python
`random.Random(20260929).shuffle` (this committed order is authoritative):
credo, floki, earmark_parser, stream_data, reactor, phoenix_pubsub, cachex,
ecto_sql, mint, timex, nimble_pool, phoenix_html, explorer, redix, ex_doc,
thousand_island, swoosh, spark, telemetry_metrics, ex_machina, bandit,
membrane_core, commanded, joken, finch, nimble_parsec, ex_aws, gettext,
db_connection, httpoison, phoenix, nimble_csv, postgrex.

**Procedure.**

1. Pin each candidate when it is drawn: the commit of the tag of its latest
   non-prerelease hex.pm release published on or before 2026-09-29, or, with
   no matching tag, the last default-branch commit on or before that date.
   Record the pin before the first build.
2. Build with `MIX_ENV=test` under the compiler of the adapter being
   measured, as in `bench/corpus/README.md` (separate `MIX_BUILD_PATH` and
   `SPEC_LINT_PLT_DIR` per compiler), and run the baseline.
3. Walk the draw order from the first candidate not yet spent. A candidate
   that fails to fetch, compile or complete, or does not meet the
   criterion, is recorded with the reason and skipped, never retried with
   changes.
4. Stop at the number of qualifying holdouts the experiment plan fixed in
   advance (3 unless the plan says otherwise).
5. Freeze the experiment's tool tree (record the source digest) before
   reading any finding of a holdout.
6. Every candidate examined, qualifying or not, is spent: it becomes a
   regression corpus and is never drawn again.

## Reproduce

```sh
OSS=...        # decimal, plug, ecto checkouts (bench/corpus/README.md)
EXPANSION=...  # oban, req, ash, absinthe checkouts (expansion.json)
elixir bench/evaluation/pinned_witnesses.exs "$OSS" "$EXPANSION"
elixir bench/corpus/expansion_witnesses.exs "$EXPANSION"
elixir bench/corpus/holdout_witnesses.exs "$EXPANSION" | jq -S .   # holdout_witnesses.json
elixir bench/corpus/ash_integration_witnesses.exs "$EXPANSION"
R=bench/corpus/reports/release-1
elixir bench/evaluation/detection.exs \
  "1.20.4+759443e=$R/1.20.4" "1.21.0-dev+648b2a9=$R/648b2a9" \
  "1.21.0-dev+c24c235=$R/c24c235" | jq -S .                        # detection_v2.json
```

The version-1 measurement at the freeze used the report sets
`reports/elixir-1.20.4/c24c235`, `reports/upstream-648b2a9`,
`reports/m1_review` and `reports/elixir-1.20.4`.

Each witness script raises when a pinned observation or verdict changes.
`pinned_witnesses.exs` loads only the ebin directories of the pinned
decimal, plug (with mime, plug_crypto, telemetry), ecto and absinthe builds,
starts no application, and does not call SpecLint; it was run under the
1.21 fork (`c24c235`).
