# Phase 0 report: SL002 usefulness experiment

Date 2026-09-28. This is the go/no-go experiment of DESIGN.md section 11,
item 1. It asks whether the section 3.1 classifier finds real missing return
alternatives often and precisely enough for `SL002` to gate CI.

## Decision

**SL002 is informational.** It is reported in both profiles and gated by
neither. The `review` profile no longer gates it. The only way to fail a
build on it is the explicit user override `--warnings-as-errors`, which
gates every reported finding (DESIGN section 4).

The numbers behind the decision:

| Measure | Value |
| --- | --- |
| SL002 candidates on real code, classifier as measured (`38be37d`) | 9 functions (stdlib 8, plug 1, the other 5 libraries 0) |
| Of those, confirmed true omissions after refutation | **0 of 9** (all 9 false-positive verdicts survived two independent refutation attempts) |
| SL002 candidates on real code after the fixes in this report | 2 (both `Calendar.ISO.parse_utc_datetime/1,2`, both refuted false positives): **0 of 2** |
| Confirmed real omissions found while triaging real code | 9 (decimal 2, plug 2, ecto 5) |
| Of those, reported as `structured_possible` (would gate) | **0 of 9**. 8 were `unknown` (7 top-only), 1 was `possible_domain_escape` |
| `whole_kind_possible` functions on real code (suppressed by the filter) | 42. 14 reviewed, **0 real omissions** |
| Fixture corpus (synthetic) | 20 of 20 classes as expected. 5 of 8 omissions detected, 1 false positive before the fix, 0 after |

On real code SL002 had no true positives and nine false positives. Every
confirmed omission landed in a class that does not warn. No gating mode is
justified on this evidence. "Opt-in gating" was also rejected: a dedicated
switch would still gate 0 true positives, and `--warnings-as-errors`
already covers a user who wants the strict policy.

**What would change the decision** (recorded in DESIGN section 12): after
open items O1 (near-top inference) and O2 (per-clause evidence under
top-only unions) are fixed, re-run this experiment on the same pinned
corpora. Promote SL002 to gating in the `review` profile only if all three
hold: at least 10 candidates are reviewed, precision is at least 80%, and at
least 3 real omissions are confirmed.

The experiment's most useful finding is not about SL002. Four of the nine
real omissions are **stale specs**: every normal return, or most of them,
is outside the spec, which is SL001-grade. A single `dynamic()` clause hid
each of them, because it made the union top-only (open item O2).

## Setup

- Toolchain: Elixir 1.21.0-dev (`c24c235`) built with Erlang/OTP 28, from
  `~/elixir`. The adapter is `SpecLint.Compiler.V121`.
- Classifier: `SpecLint.Evidence` as committed in `38be37d`. All triage
  used this version. The fixes in "Tool bugs" below were made afterwards,
  and every corpus was re-run with them ("post-fix" columns).
- Runner: `MIX_ENV=test mix run bench/experiment.exs -- --ebin DIR ...
  --code-path DIR ... --label NAME --out FILE`. For the OSS libraries, every
  `_build/test/lib/*/ebin` of the project is on `--code-path`, so remote
  types resolve.
- Corpora:
  - The stdlib: `~/elixir/lib/{elixir,eex,ex_unit,iex,logger,mix}/ebin`.
  - Six OSS libraries, compiled with `MIX_ENV=test`: jason `4ede428`
    (v1.4.5), decimal `92a28e6`, nimble_options `825c058`, mime `23dcc15`,
    plug `73404f8` and ecto `94d6927`.
  - The fixtures: `test/support/experiment_fixtures.ex`, with expected
    classes in `SpecLint.ExperimentFixtures.expected/0`.
- Raw results: `scratchpad/results/*.json` (as measured) and
  `scratchpad/results_postfix/*.json` (post-fix). The as-measured jason
  file was lost from the shared scratchpad, so its as-measured numbers come
  from the triage report. Its post-fix file is present.

### Triage method

- **Sample.** Every function classed `structured_possible` was read (the cap
  was 40; the most any corpus had was 8). The other classes were sampled at
  random, with the seed 20260928 over the list sorted by MFA:
  - up to 15 `possible_domain_escape`;
  - up to 10 `whole_kind_possible`;
  - 10 `unknown`.
  Corpora small enough were read in full.
- **Verdicts.** For a class that warns, `false_positive` means the reported
  extra cannot happen for any in-spec input. For a class that does not
  warn, the same verdict means the silence was correct. `true_omission`
  means a real undeclared normal return for an in-spec input. Wherever a
  claim could be checked by running the function, it was run.
- **Refutation.** Every false-positive verdict on a warning class and every
  true-omission verdict went to two independent agents, each asked to
  refute it. There were 18 claims: the 9 SL002 false positives and the 9
  true omissions. None was refuted.

| Corpus | Functions reviewed | Of which true omissions |
| --- | --- | --- |
| stdlib | 43 (8 structured, 15 domain escape, 10 whole kind, 10 unknown) | 0 |
| jason | 11 (1 domain escape, 10 unknown) | 0 |
| decimal | 13 (2 whole kind, 10 unknown, plus `compare/2`) | 2 |
| nimble_options | 5 (all 5 unknown) | 0 |
| mime | 5 (all `none`, checked as a negative control) | 0 |
| plug | 14 (1 structured, 2 domain escape, 1 whole kind, 10 unknown) | 2 |
| ecto | 16 (3 domain escape, 1 whole kind, 10 unknown, plus 2 found by a per-clause probe) | 5 |
| **Total** | **107** | **9** |

The stdlib triage note says 53 functions. The sample it lists has 43
entries, and 43 is used here.

## Fixture accuracy

All 20 fixture functions get their expected class, both before and after
the fixes. The warn/no-warn outcomes are below.

| Fixture | Case | Class | Real omission | Outcome |
| --- | --- | --- | --- | --- |
| `lookup/1` | `{:error, :missing}` | structured_possible | yes | detected |
| `status/1` | atom `:timeout` | structured_possible | yes | detected |
| `point/1` | struct return plus `:origin` | structured_possible | yes | detected |
| `fetch/1` | struct in the extra | structured_possible | yes | detected |
| `labels/1` | list extra `[:two]` | structured_possible | yes | detected |
| `size_of/1` | whole kind: spec `integer()`, body also `binary()` | whole_kind_possible | yes | suppressed |
| `secret/1` | opaque remote return hides the omission | none | yes | suppressed |
| `passthrough/1` | `tuple()` minus `{:ok, _}` (negation) | unknown | yes | suppressed |
| `wrap_error/1` | wider payload via helper, tag in spec | structured_possible, **unknown after fix** | no | false positive, **true negative after fix** |
| `pick/1` | overlapping overloads; the `overlap` tag blocks | structured_possible | no | true negative |
| `name/1` | multi-clause catch-all | none | no | true negative |
| `display/1` | catch-all inside one `case` | possible_domain_escape | no | true negative |
| `kind/1` | incomparable domains | possible_domain_escape | no | true negative |
| `sign/1` | `pos_integer()` input | possible_input_approximate | no | true negative |
| `decode/1` | Erlang BIF, top-only | unknown | no | true negative |
| `find_key/2` | recursion returns `dynamic()` | unknown | no | true negative |
| `count/1` | `1 + dynamic()` gives extra `float()` | whole_kind_possible | no | true negative |
| `wide/1` | deliberately wide spec | none | no | true negative |
| `fail!/1` | `no_return()` | none | no | true negative |
| `wrap/1` | helper outside its domain (badapply) | none | no | true negative |

Totals as measured: 5 detected, 3 suppressed, 1 false positive, 11 true
negatives. After the fix: 5 detected, 3 suppressed, 0 false positives, 12
true negatives.

The fixtures were written to exercise the classifier. They say nothing
about how often each pattern occurs in real code.

## Per-corpus results

### Coverage and runtime

| Corpus | Modules (ok / out of scope) | Functions | Slices (exact / approximate) | Unsupported | Unavailable | Out-of-scope specs | Runtime |
| --- | --- | --- | --- | --- | --- | --- | --- |
| stdlib | 447 (413 / 34 Erlang) | 1807 | 1969 (1088 / 881) | 0 | 0 | 30 protocol, 4 macro, 3 not exported | 1466 ms |
| jason | 28 (28 / 0) | 35 | 50 (30 / 20) | 0 | 0 | 4 protocol, 1 not exported | 85 ms |
| decimal | 7 (7 / 0) | 49 | 52 (6 / 46) | 0 | 0 | none | 41 ms |
| nimble_options | 4 (4 / 0) | 6 | 7 (6 / 1) | 0 | 0 | none | 26 ms |
| mime | 1 (1 / 0) | 5 | 5 (3 / 2) | 0 | 0 | 3 not exported | 15 ms |
| plug | 62 (61 / 1 Erlang) | 88 | 90 (22 / 68) | 0 | 0 | 5 protocol | 190 ms |
| ecto | 102 (102 / 0) | 180 | 195 (61 / 134) | 0 | 0 | 4 not exported, 3 protocol | 298 ms |
| fixtures (project test ebin) | 20 (20 / 0) | 193 | 196 (138 / 58) | 0 | 0 | 4 protocol, 1 macro, 1 not exported | 64 ms |

- **No unsupported or unavailable slice.** No corpus had a slice that was
  unsupported or unavailable, for any reason.
- **Runtime.** The analysis phase is well under two seconds even on the
  stdlib (about 2 s wall clock with VM start). The post-fix runs took the
  same time, within noise.
- **Generated `__impl__/1` functions inflate the counts** (open item O7):
  - stdlib: 96 functions, 192 slices;
  - jason: 15;
  - ecto: 15;
  - decimal: 3;
  - plug: 2;
  - nimble_options: 1.

  All of them are `none`.

### Function classes

As measured (`38be37d`), with the post-fix number in parentheses where it
differs:

| Corpus | structured_possible | possible_domain_escape | possible_input_approximate | whole_kind_possible | unknown | none |
| --- | --- | --- | --- | --- | --- | --- |
| stdlib | 8 (2) | 17 (2) | 0 | 38 (39) | 989 (1009) | 755 |
| jason | 0 | 1 (0) | 0 | 0 | 15 (16) | 19 |
| decimal | 0 | 0 | 0 | 2 | 28 | 19 |
| nimble_options | 0 | 0 | 0 | 0 | 5 | 1 |
| mime | 0 | 0 | 0 | 0 | 0 | 5 |
| plug | 1 (0) | 2 (0) | 0 | 1 | 75 (78) | 9 |
| ecto | 0 | 3 (1) | 0 | 1 | 137 (139) | 39 |
| **Real code total** | **9 (2)** | **23 (3)** | **0** | **42 (43)** | **1249 (1275)** | **847** |

Slice classes on the stdlib, as measured:
- unknown 1019;
- none 872;
- whole_kind_possible 52;
- possible_domain_escape 18;
- structured_possible 8.

Post-fix: unknown 1039, none 872, whole_kind_possible 53,
possible_domain_escape 3, structured_possible 2.

**Top-only slices**, which are `unknown` before any structure is examined:

| Corpus | Top-only slices |
| --- | --- |
| stdlib | 913 of 1969 (46%) |
| jason | 14 of 50 |
| decimal | 23 of 52 |
| nimble_options | 4 of 7 |
| mime | 0 of 5 |
| plug | 34 of 90 |
| ecto | 84 of 195 |

**Overlap tags:**
- stdlib: 18 slices;
- fixtures: 4 slices;
- every other corpus: 0.

### Loss kinds (count of loss records)

| Corpus | Loss kinds |
| --- | --- |
| stdlib | integer_refinement_erased 746, recursive_cutoff 281, type_variable_correlation 104, arrow_polarity 94, map_key_widened 56, charlist_as_integers 33, opaque_boundary 19, record_fields_unknown 16, sized_binary_erased 5 |
| jason | recursive_cutoff 20, arrow_polarity 7 |
| decimal | integer_refinement_erased 46, arrow_polarity 1, type_variable_correlation 1 |
| nimble_options | recursive_cutoff 1 |
| mime | integer_refinement_erased 1, map_key_widened 1, recursive_cutoff 1 |
| plug | integer_refinement_erased 66, recursive_cutoff 66, map_key_widened 3, arrow_polarity 2, unresolved_remote_type 2 |
| ecto | recursive_cutoff 119, map_key_widened 101, arrow_polarity 75, integer_refinement_erased 39, sized_binary_erased 9, type_variable_correlation 1 |

- **`integer_refinement_erased` makes a slice approximate.** Its main
  sources are `non_neg_integer()`, `pos_integer()`, literal integers and
  `1 | -1` in struct fields. One such loss marks the whole slice
  `input_approximate`, even when the function never reads the field. For
  example, `Plug.Conn.t()` alone makes 66 of plug's 90 slices approximate,
  and `Decimal.t()` makes 46 of decimal's 52.

## SL002 precision after refutation

| Corpus | Candidates reviewed | True omissions confirmed | After the fix |
| --- | --- | --- | --- |
| stdlib | 8 | 0 | 2 candidates, both already refuted |
| plug | 1 | 0 | 0 candidates |
| jason, decimal, nimble_options, mime, ecto | 0 | none | 0 candidates |
| **Total** | **9** | **0 (precision 0/9)** | **2 candidates, 0/2** |

- **The candidates have one shape.** All 9 were a wider payload under a tag
  the spec already declares (`tag_in_spec?`), such as `{:ok, not pid()}`
  under a spec that says `{:ok, pid()}`.
- **Seven of them are artefacts of subtraction.** The contributing clause
  returned `{:ok, term()}` or similar. The `not pid()` payload was produced
  by subtracting the spec, not inferred from code. That is exactly what
  DESIGN 3.1 step 5 forbids counting (fixed as F1).
- **The two that remain are real inference, just imprecise.**
  `Calendar.ISO.parse_utc_datetime/1,2` get `float()` from arithmetic on the
  unguarded parameters of a private helper. The offset is always an integer
  at runtime.
- **Every contributing clause of the 9 candidates had a gradual
  (non-static) return.** Requiring a static contributing return (DESIGN
  section 12) would have removed all 9. On the fixtures it would also drop
  2 of the 5 detections: `point/1` and `fetch/1` build structs, and their
  clause returns are gradual.

## What the whole-kind filter suppressed

| Corpus | `whole_kind_possible` functions | Reviewed | Real omissions |
| --- | --- | --- | --- |
| stdlib | 38 | 10 | 0 |
| decimal | 2 | 2 | 0 |
| plug | 1 | 1 | 0 |
| ecto | 1 | 1 | 0 |
| jason, nimble_options, mime | 0 | none | none |
| **Total** | **42** | **14** | **0** |

The causes, in order of frequency:

- **Near-top inference evades the top-only guard** (O1). Returns inferred as
  one of these are not top-only, so every base kind outside the spec becomes
  a counted whole-kind component:
  - `dynamic(not :undefined)`, from `Process.put` or a `nilify` of a BIF;
  - `dynamic(not false and not nil)`, from `x || raise`;
  - `dynamic(not empty_list())`, from `Ecto.primary_key!/1`;
  - `term()` minus one tuple shape, from the `with` fall-through in
    `JSON.decode/1`.

  This accounts for 27 of the 38 stdlib functions, and for Ecto.
- **Numeric widening from unconstrained operands.** Examples:
  - `Decimal.scale/1` and `to_integer/1`, where struct fields are `term()`
    and `-exp` or `sign * coef` is `number()`;
  - stdlib arithmetic such as `Kernel.+/2`, `Float.round` and `Date.diff`.
- **Literal-integer erasure**: `Macro.generate_unique_arguments/2`, where the
  spec's `0` becomes `integer()`.
- **Truthiness-only knowledge**: `Plug.Conn.get_session/1`.

The fixture `size_of/1` shows that the filter does hide real whole-kind
omissions. None turned up in the 14 reviewed real-code functions.

## Real omissions found, and where they landed

| Function | Corpus | Kind of omission | Class (as measured → post-fix) | Why it was hidden |
| --- | --- | --- | --- | --- |
| `Decimal.compare/2` | decimal | returns the NaN `%Decimal{}` when `:invalid_operation` is not trapped | unknown | top-only (the `error/4` macro gives `dynamic()`) |
| `Decimal.cmp/2` | decimal | same, by delegation | unknown | top-only |
| `Plug.Conn.Query.decode/4` | plug | atom keys from a keyword `initial` (the spec's argument is too wide) | unknown | top-only |
| `Plug.Conn.merge_private/2` | plug | non-atom keys in `private` (the spec's argument is too wide) | unknown | struct-minus-struct negation component |
| `Ecto.Changeset.apply_action/2` | ecto | `{:ok, nil}` for a changeset with `data: nil` | possible_domain_escape → unknown | escape. The only evidence was a subtraction payload that coincidentally contained `nil` |
| `Ecto.Query.Builder.Join.escape/3` | ecto | stale spec: 5-tuples returned, 4-tuple declared | unknown | top-only (recursive catch-all clause) |
| `Ecto.Query.Builder.quoted_type/2` | ecto | stale spec: `:atom`, `{:tuple, _}`, `as`/`parent_as` pairs | unknown | top-only (recursive clauses) |
| `Ecto.Repo.Assoc.query/4` | ecto | stale spec: list of rows, not of schemas | unknown | top-only (`Enum.map` with a spec'd fun) |
| `Ecto.Repo.Preloader.query/7` | ecto | stale spec: elements are whatever `fun` returns | unknown | top-only (`Enum.map` with an untyped fun) |

- **How many were visible to SL002.** Seven of the nine are behind
  union-level top-only inference. Each has at least one precise contributing
  clause whose return is disjoint from `S_hi`, or not inside it.
- **What found them.** The ecto per-clause probe
  (`scratchpad/ecto_triage/per_clause.exs`) ran over all 84 top-only slices.
  It surfaced 17 slices with a non-empty per-clause extra; 4 were real, and
  the rest were imprecise payloads in structs and escaped ASTs.
- **Three of the four stale specs are internal.** They are in
  `@moduledoc false` modules.

## Most common false-positive causes

These were measured across all warning and near-warning classes on real
code.

1. **A wider payload under a declared tag, from `term()` payloads.** The
   payload is `term()` because of one of these:
   - an Erlang BIF without a return type (`:erlang.iolist_to_binary/1`,
     `float_to_binary/2`, `:binary.at/2`);
   - a read from ETS, the process dictionary or Agent state;
   - dynamic remote or protocol dispatch;
   - recursion.

   This covers 8 of the 9 SL002 candidates, 13 of the 15 sampled stdlib
   `possible_domain_escape`, plug `read_body/2` and `SSL.configure/1`, ecto
   `cast_value/3`, and jason `encode/2`. It is fixed by F1.
2. **Near-top inference evading the top-only guard.** This covers 27 of the
   38 stdlib `whole_kind_possible`, `Ecto.primary_key!/1` and `JSON.decode/1`
   (open O1).
3. **Imprecise but not top payloads.** Examples:
   - arithmetic on unguarded parameters (`Calendar.ISO`, `DateTime`);
   - the falsy branch of `&&` typed as `false or nil`
     (`Ecto.Changeset.field_missing?/2`);
   - numeric expressions over unconstrained struct fields (decimal).

   These are what remain after F1.
4. **Lost input/output correlation in a single inferred clause**:
   `Kernel.not/1` and `System.get_env/2`. They are correctly blocked by
   `domain_escape`. They are the only stdlib slices with a structured
   component that is not a payload under a declared tag.
5. **Literal-integer erasure in specs.** This creates false overlap tags and
   whole-kind extras (`Macro.generate_unique_arguments/2`).

Structural observations that bound SL002 regardless of bugs:

- **Containment is rare.** On the stdlib, 1192 of 2185 contributing clauses
  are `domain_escape`, mostly because unguarded parameters are inferred as
  `term()`.
- **Struct arguments block `structured_possible`.** Any function taking a
  struct with typed fields escapes: patterns such as `%Decimal{}` or
  `%Ecto.Changeset{}` leave fields `term()`. Any typed field with an
  integer refinement also makes the slice approximate. Together these make
  `structured_possible` unreachable for typical struct APIs (decimal, plug,
  ecto).
- **Negation components.** Most non-top `unknown` slices in plug and ecto
  are a struct minus a struct: the inferred struct has untyped fields and
  the translated spec is precise.

## Tool bugs

### Fixed in this change (with tests)

- **F1: payloads refined only by subtracting the spec counted as
  structured.** This deviated from DESIGN 3.1 step 5.
  - The bug: `{:ok, not pid()}` from a clause returning `{:ok, term()}` was
    labelled `:structured` and treated as present in contributing.
  - The fix: `SpecLint.Evidence` now marks a `tag_in_spec?` component as
    `subtraction_payload?`, and not present, when every contributing return
    component with the same label that it overlaps has `term()` at a
    position where the component is narrower. Positions are tuple elements
    or struct fields, compared to three levels deep. The new reason is
    `{:subtraction_payload, n}`.
  - A payload that inference really narrowed, such as `{:ok, integer()}`, a
    new tag, or one precise witness among `term()` payloads, still counts.
  - Effect on real code:
    - SL002 candidates went from 9 to 2.
    - `possible_domain_escape` went from 23 to 3.
    - `JSON.decode/1` moved to `whole_kind_possible` (O1).
    - The `wrap_error/1` fixture is now `unknown`, a true negative.
- **F2: `Compiler.to_string/1` printed an empty lazy difference as a
  non-empty type.** For example, the extra of `MIME.known_types/0` printed
  as `%{binary() => non_empty_list(binary())} and not %{binary() =>
  list(binary())}`. `V121.to_string/1` now prints `none()` when the type is
  empty. Classification was never affected.
- **F3: containment ignored `D_lo`.** `Compare` decided containment on
  `D_hi` only, so a clause of an approximate slice was
  `containment_unknown` even when `I_k ⊆ D_lo` proved containment. Since
  `D_lo ⊆ D`, such a clause is now `:contained`. This is conservative and
  does not change any corpus class.

### Open

- **O1: near-top inference evades `top_only?`.**
  - The problem: `top_only?` requires `term() ⊆ U(D)`. Returns such as
    `dynamic(not :undefined)`, `dynamic(not false and not nil)`,
    `dynamic(not empty_list())` and `term()` minus one tuple shape are not
    caught. Every base kind outside the spec is then counted as a whole-kind
    component.
  - Reproductions: `Config.config/3`, `Ecto.primary_key!/1`, and
    `SpecLintRepro.NearTop.pk!/1` in
    `scratchpad/ecto_triage/near_top.ex`.
  - A possible fix: treat `U(D)` as near-top when its upper bound covers
    every base kind except a finite set of literals, or when the extra
    covers pid, port, reference and fun whole. This is a heuristic, so it
    is left open.
- **O2: top-only masking of per-clause conflicts.** This is a design gap.
  - The problem: when the union `U(D)` is top-only, the classifier returns
    `unknown` without looking at the contributing clauses. One `dynamic()`
    clause (recursion, `Enum.map` with a fun, protocol dispatch) hides
    precise clauses whose returns are disjoint from `S_hi`.
  - Impact: this hid four ecto stale specs, plus Decimal
    `compare/2`/`cmp/2` and `Plug.Conn.Query.decode/4`.
  - Reproduction: `SpecLintRepro.NearTop.esc/1` in
    `scratchpad/ecto_triage/near_top.ex`.
  - The proposal: classify the non-top contributing clauses one by one, and
    report per-clause disjointness as an SL001 candidate. This needs design
    work on gating, so it is left open.
- **O3: the evidence heuristic for imprecise but not top payloads.**
  - The problem: after F1, `{:ok, _, float()}` under `{:ok, _, integer()}`
    still counts when inference derived `float()` from arithmetic on
    `term()`. Both remaining stdlib candidates are this case.
  - Whether requiring a static contributing return is the right filter is
    in DESIGN section 12.
- **O4: unreadable messages.** Nested negations in extras print
  unsimplified. Examples are `NimbleOptions.validate/2`, which prints as
  `not (A and not B) and not B`, and `Plug.Upload.random_file/1`. This
  needs normalising before Phase 1 messages ship.
- **O5: literal integers in specs are erased to `integer()`.** This causes
  false overlap tags between, for example, a `0` slice and a `pos_integer()`
  slice (`Macro.generate_unique_arguments/2`). It belongs to Phase 0 item 2,
  translation.
- **O6: `whole_kind_possible` ignores input approximation and domain
  escape.** See `Macro.generate_unique_arguments/2` slice 0. The class is
  report-only, so this is low priority.
- **O7: the runner counts generated `__impl__/1` functions in its totals.**
  Report them separately, or exclude them as generated definitions (DESIGN
  section 8 scope).

### Fixed after the report (DESIGN 3.1 steps 7 to 9)

All of O1 to O7 are addressed. Results are in
`scratchpad/results_perclause/*.json`, produced by the runner, which now
classifies every slice twice (`require_static_return` false and true) and
reports per-clause evidence.

- **O1, near-top.** `SpecLint.Compare.near_top?/2` implements step 8. On
  the stdlib, 32 slices are near-top, among them `Config.config/3`,
  `Process.put/2` and `JSON.decode/1`. 28 of the 39 stdlib
  `whole_kind_possible` functions became `unknown`.
- **O2, per-clause evidence.** Step 7 is implemented in
  `SpecLint.Evidence`. The new class `clause_conflict` is the worst class.
  It needs a contained clause whose stored return is disjoint from `S_hi`.
  On the fixtures it detects `lookup/1`, `size_of/1`, `labels/1` and the
  new `stale/1` (the `Join.escape/3` shape). On real code it finds nothing:
  the clauses of the four stale ecto specs all escape the spec domain,
  because their parameters are unguarded. They now show as
  `possible_domain_escape` (`Join.escape/3` and `quoted_type/2`) rather
  than `unknown`. The other two stay `unknown`: their non-top clause
  extras have no structured or whole-kind component.
- **O3, gradual payloads.** Step 9 is implemented. The option is
  `require_static_return`, the class `possible_gradual`, and the component
  flag `payload_gradual?`. The default stays `false` until a re-triage
  chooses otherwise. With `true`:
  - both stdlib SL002 candidates become `possible_gradual`;
  - on the fixtures, 5 of 8 detections are lost (`size_of/1`,
    `point/1`, `fetch/1`, `stale/1`, `gradual_payload/1`); 2 of them are
    clause conflicts whose clause returns are gradual;
  - no stdlib clause conflict exists under either setting.
- **O4, printing.** `V121.to_string/1` prints static types from their
  normal form. Tuples and maps are printed line by line, with dead
  negations dropped, and the complement form is used when it is shorter.
  `term()` minus the NimbleOptions result type now prints as
  `not ({:error, ...} or {:ok, ...})`.
- **O5, integer literals.** Integer literals, ranges and refinements keep
  their intervals in `SpecLint.Bound` (`integers`). Overlap between
  overloads has three outcomes:
  - certain (`overlap?`) when the lower bounds meet;
  - none when the upper bounds are disjoint or an integer position has
    disjoint intervals;
  - `overlap_unknown?` otherwise.

  Stdlib overlap tags went from 18 to 0 certain and 2 unknown.
- **O6, whole kinds.** Whole-kind evidence with a certain escape is
  `possible_domain_escape`, and with input approximation it is
  `possible_input_approximate`. Both carry the reason `whole_kind_only`.
  7 plus 4 stdlib functions moved.
- **O7, generated definitions.** Definitions marked `generated: true` in
  debug info, and the compiler's `__impl__/1`, `__protocol__/1`,
  `__struct__/0,1`, `__info__/1` and `__deriving__/3`, are out of scope with
  the reason `generated`. That removes 96 stdlib functions, 15 each in
  jason and ecto, 3 in decimal, 2 in plug and 1 in nimble_options.

Stdlib function classes after the fixes (1711 functions):

| Setting | unknown | none | possible_domain_escape | possible_input_approximate | structured_possible | possible_gradual | clause_conflict |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `require_static_return: false` | 1035 | 659 | 11 | 4 | 2 | 0 | 0 |
| `require_static_return: true` | 1035 | 659 | 11 | 4 | 0 | 2 | 0 |

Not a bug:
- **Maps whose keys follow an `optional(any)`.** Such map types
  (`Calendar.time()`, `Ecto.Schema.t()`) translate with the later keys
  shadowed. This matches Dialyzer's `erl_types:map_from_form/6`. It is
  Dialyzer-faithful but not what the spec author intended; worth a note in
  the translation docs.
- **Spec gaps outside function returns.** Plug's `@type state` omits
  `:set_upgrade`, which `before_send` callbacks can observe. That is a spec
  gap in plug, but no return-based rule can see it.

# Phase 1 rerun

Date 2026-09-28. The same pinned corpora and toolchain as Phase 0, run with
the classifier at `70316ce` (DESIGN 3.1 steps 7 to 9: per-clause evidence,
near-top, gradual payloads). Every slice was classified twice, with
`require_static_return` false and true. Raw results:
`scratchpad/results_phase1/*.json` (real code) and
`scratchpad/results_perclause/fixtures.json` (fixtures, 23 functions).

This rerun is the revisit of DESIGN section 12 and decides three defaults
before the Phase 1 product (Mix task, rules, baseline) is built on them.

## Decisions

1. **`require_static_return` defaults to `false`.** On 2038 real-code
   functions the setting changes exactly two functions, both
   `Calendar.ISO.parse_utc_datetime/1,2`, from `structured_possible` to
   `possible_gradual`. Both classes are report-only, and both functions are
   false positives refuted in Phase 0, so `true` removes no gated noise.
   On the fixtures, `true` loses 5 of 8 detections, including 2 of the 4
   clause conflicts (`size_of/1` and `stale/1`, the `Join.escape/3`
   stale-spec shape). That is recall on the one gating class, for no
   measured precision gain. The option stays available in `.spec_lint.exs`.
2. **`clause_conflict` gates in both profiles, as designed.** It had 0
   candidates on real code under either setting, so it adds no gated
   findings and no false positives on 2038 functions. On the fixtures it
   detects 4 of 4 intended cases (`lookup/1`, `labels/1`, `size_of/1`,
   `stale/1`) with 0 false positives, and the overlap prerequisite
   correctly blocks `pick/1`. Real-code precision is still unmeasured
   (0/0). The first confirmed real-code false positive reopens this. The
   prerequisite "the compiler did not flag the clause unreachable" cannot
   be checked from the checker chunk. It is reported as unchecked, not as
   met.
3. **SL002 stays informational.** None of the three revisit conditions of
   DESIGN section 12 holds: 2 candidates were reviewed (at least 10
   needed), precision is 0 of 2 (at least 80% needed), and 0 omissions
   were confirmed (at least 3 needed).

## Coverage and runtime

| Corpus | Modules (ok / out of scope) | Functions | Slices (exact / approximate) | Out-of-scope specs | Top-only / near-top slices | Overlap (certain / unknown) | Runtime |
| --- | --- | --- | --- | --- | --- | --- | --- |
| stdlib | 447 (413 / 34 Erlang) | 1711 | 1777 (896 / 881) | 96 generated, 30 protocol, 4 macro, 3 not exported | 913 / 32 | 0 / 2 | 2743 ms |
| jason | 28 (28 / 0) | 20 | 20 (0 / 20) | 15 generated, 4 protocol, 1 not exported | 14 / 0 | 0 / 0 | 92 ms |
| decimal | 7 (7 / 0) | 46 | 46 (0 / 46) | 3 generated | 23 / 0 | 0 / 0 | 66 ms |
| nimble_options | 4 (4 / 0) | 5 | 5 (4 / 1) | 1 generated | 4 / 0 | 0 / 0 | 31 ms |
| mime | 1 (1 / 0) | 5 | 5 (3 / 2) | 3 not exported | 0 / 0 | 0 / 0 | 15 ms |
| plug | 62 (61 / 1 Erlang) | 86 | 86 (18 / 68) | 5 protocol, 2 generated | 34 / 1 | 0 / 0 | 402 ms |
| ecto | 102 (102 / 0) | 165 | 165 (31 / 134) | 15 generated, 4 not exported, 3 protocol | 84 / 1 | 0 / 0 | 694 ms |
| **Real code** | **651** | **2038** | **2104 (952 / 1152)** | | **1072 / 34** | **0 / 2** | |

No corpus had an unsupported or unavailable slice. The function counts are
lower than in Phase 0 because generated definitions (O7) are now out of
scope.

## Function classes

The same numbers under both settings unless two values are shown
(`false` / `true`).

| Corpus | clause_conflict | structured_possible | possible_gradual | possible_domain_escape | possible_input_approximate | whole_kind_possible | unknown | none |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| stdlib | 0 | 2 / 0 | 0 / 2 | 11 | 4 | 0 | 1035 | 659 |
| jason | 0 | 0 | 0 | 0 | 0 | 0 | 16 | 4 |
| decimal | 0 | 0 | 0 | 2 | 0 | 0 | 28 | 16 |
| nimble_options | 0 | 0 | 0 | 0 | 0 | 0 | 5 | 0 |
| mime | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 5 |
| plug | 0 | 0 | 0 | 0 | 0 | 0 | 79 | 7 |
| ecto | 0 | 0 | 0 | 4 | 0 | 0 | 137 | 24 |
| **Real code** | **0** | **2 / 0** | **0 / 2** | **17** | **4** | **0** | **1300** | **715** |

Per-clause classes (DESIGN 3.1 step 7), over all contributing clauses:

- stdlib: unknown 1155, none 88, possible_domain_escape 24,
  possible_input_approximate 3, whole_kind_possible 3, structured_possible
  2 (`true`: possible_gradual 2), clause_conflict 0;
- ecto: unknown 195, none 101, possible_domain_escape 13, clause_conflict 0.
  Of 309 contributing clauses, 54 are contained, 246 escape the spec domain
  and 9 have unknown containment;
- decimal: 6 of 102 clauses contained, 95 escape, 1 unknown;
- plug: 10 of 107 clauses contained, 97 escape.

Containment is the binding constraint. Most clauses of real code escape
the spec domain because unguarded parameters and struct patterns infer as
`term()` fields, so per-clause evidence rarely reaches a gating class.

## Precision after refutation

No new candidate appeared in a gating or near-gating class, so this rerun
had nothing new to refute (refutation set: empty). The two remaining
candidates were refuted twice in Phase 0.

| Class | Setting | Real-code candidates | Confirmed true | Precision | Fixture detections / false positives |
| --- | --- | --- | --- | --- | --- |
| `clause_conflict` (SL001, gated) | `false` | 0 | 0 | n/a (0/0) | 4 / 0 (`pick/1` blocked by overlap) |
| `clause_conflict` (SL001, gated) | `true` | 0 | 0 | n/a (0/0) | 2 / 0 (`size_of/1`, `stale/1` become `possible_gradual`) |
| `structured_possible` (SL002) | `false` | 2 | 0 | 0/2 (0%) | 4 / 0 (`status/1`, `point/1`, `fetch/1`, `gradual_payload/1`) |
| `structured_possible` (SL002) | `true` | 0 | 0 | n/a (0/0) | 1 / 0 (`status/1`; the other three become `possible_gradual`) |
| `possible_gradual` (SL002, report) | `true` | 2 | 0 | 0/2 (0%) | not a detection class |

Other reviewed classes (not gating, report-only):

- stdlib: all 11 `possible_domain_escape` functions were reviewed. None is
  an omission: they are numeric widening in `Kernel` arithmetic,
  `DateTime.to_unix/2`, `Time.diff/3` and `String.count/2`, and the lost
  input/output correlation of `Kernel.not/1` and `System.get_env/2`;
- decimal: `scale/1` and `to_integer/1` (numeric widening over `term()`
  struct fields), 0 omissions;
- ecto: 4 reviewed. `Join.escape/3` and `quoted_type/2` are the known stale
  specs, `field_missing?/2` and `CTE.escape/2` are not omissions;
- jason: 6 extra `unknown` functions reviewed, nimble_options 5, 0
  omissions.

## Recall on the known omissions

The 9 real omissions confirmed in Phase 0:

| Function | Class now (both settings) | Gated | Reported |
| --- | --- | --- | --- |
| `Decimal.compare/2` | unknown (top-only) | no | no |
| `Decimal.cmp/2` | unknown (top-only) | no | no |
| `Plug.Conn.Query.decode/4` | unknown (top-only) | no | no |
| `Plug.Conn.merge_private/2` | unknown (struct negation component) | no | no |
| `Ecto.Changeset.apply_action/2` | unknown | no | no |
| `Ecto.Query.Builder.Join.escape/3` | possible_domain_escape | no | yes (SL002) |
| `Ecto.Query.Builder.quoted_type/2` | possible_domain_escape | no | yes (SL002) |
| `Ecto.Repo.Assoc.query/4` | unknown | no | no |
| `Ecto.Repo.Preloader.query/7` | unknown | no | no |

- **Gating recall: 0 of 9** under both settings.
- **Reported recall: 2 of 9**, up from 0 of 9 in Phase 0. Per-clause
  evidence moved the two stale ecto specs out of `unknown`. Their clauses
  still escape the spec domain (unguarded parameters), so they cannot
  reach `clause_conflict`.
- The other 7 stay `unknown`. 4 of them are top-only with no non-top
  contributing clause that has structured or whole-kind extra.

## Fixtures

23 of 23 fixture functions get their expected class under both settings.

| Setting | Detected | Suppressed | False positive | True negative |
| --- | --- | --- | --- | --- |
| `require_static_return: false` | 8 | 2 | 0 | 13 |
| `require_static_return: true` | 3 | 7 | 0 | 13 |

The two omissions suppressed under both settings are `secret/1` (opaque
remote return) and `passthrough/1` (a negation component), as in Phase 0.

# Post-Phase 1 review re-measurement

Date 2026-09-28. The same pinned toolchain, re-run after the review fixes
(clause reachability approximation, the F1 widening check, the
`arrow_polarity` argument prerequisite, fingerprint normalisation and the
CI and baseline fixes; DESIGN 3.1 steps 5 and 7, sections 4 and 9.1). Raw
results: `scratchpad/rv_before/*.json` (at `9b7c4d0`) and
`scratchpad/rv_after/*.json`.

## Stdlib

| Measure | Before | After |
| --- | --- | --- |
| Functions / slices compared | 1711 / 1777 | 1711 / 1777 |
| Function classes | unknown 1035, none 659, possible_domain_escape 11, possible_input_approximate 4, structured_possible 2 | unknown 1033, none 659, possible_domain_escape 13, possible_input_approximate 4, structured_possible 2 |
| Slice classes | unknown 1066, none 680, possible_domain_escape 25, possible_input_approximate 4, structured_possible 2 | unknown 1064, none 680, possible_domain_escape 27, possible_input_approximate 4, structured_possible 2 |
| Clause classes | unknown 1155, none 88, possible_domain_escape 24, possible_input_approximate 3, whole_kind_possible 3, structured_possible 2 | unknown 1153, none 88, possible_domain_escape 26, possible_input_approximate 3, whole_kind_possible 3, structured_possible 2 |
| SL001 clause-conflict candidates | 0 | 0 |
| SL002 `structured_possible` candidates | 2 (`Calendar.ISO.parse_utc_datetime/1,2`) | 2 (the same) |
| `mix spec_lint --ci` findings | 31 SL002, 0 gating, exit 0 | 33 SL002, 0 gating, exit 0 |

The only class change is `DateTime.from_iso8601/2,3`, `unknown` to
`possible_domain_escape`. The F1 widening check now counts the component
`{:ok, %DateTime{...}, float()}`: the struct fields were narrowed by the
subtraction, but the `float()` offset comes from the code, from arithmetic
on unguarded values. That is the O3 shape of the refuted
`Calendar.ISO.parse_utc_datetime/1,2` candidates, so it is a report-only
false positive. The clause escapes the spec domain, so it cannot reach a
gating class.

Clause reachability: 23 contributing clauses in 22 stdlib functions are
possibly shadowed (for example `Enum.take/2` clause 1, whose earlier
clause's stored domain covers it because guards are not stored). None of
them is a conflict (14 `unknown`, 9 `none`), so the over-approximation
changes no stdlib result.

The ledger now splits the 1064 `unknown` obligations by reason: top_only
796, no_counted_component 239, near_top 29.

## Fixtures

25 of 25 fixture functions get their expected class under both settings.
Two fixtures were added:

- `shadowed/1`, the redundant-clause shape (`def g(a) when is_atom(a)`
  then `def g(:x)`). Its class is `clause_conflict`, and the reachability
  prerequisite blocks the gate: a true negative.
- `narrowed_payload/2`, the F1 shape (spec `{:ok, pid(), :a}`, clause
  returns `{:ok, term(), :a or :b}`). It is `structured_possible` and
  detected; before the widening check it was `unknown`.

| Setting | Detected | Suppressed | False positive | True negative |
| --- | --- | --- | --- | --- |
| `require_static_return: false` | 9 | 2 | 0 | 14 |
| `require_static_return: true` | 3 | 8 | 0 | 14 |

The four clause-conflict detections (`lookup/1`, `labels/1`, `size_of/1`,
`stale/1`) are unchanged: none of their conflicting clauses is shadowed and
none has an `arrow_polarity` argument.

# Body backend experiment

Date 2026-09-28. DESIGN section 7, STATUS next step 1, external review
item 4. The question: does type-checking function bodies under the
argument domain of one spec slice find the nine known omissions that the
stored signature misses? Does it add false positives on the fixtures or on
real code, and what does it cost?

## Decision

**Body analysis does not materially improve recall, so it is not added to
the product.** SpecLint stays signature-only: SL007 and `analysis: :bodies`
keep exiting 2, and `SpecLint.Bodies` is not built.

On the nine known omissions:

- **Gating recall goes from 0 of 9 to 1 of 9.**
  `Ecto.Query.Builder.quoted_type/2` becomes a gated `clause_conflict`. Its
  `:atom` clause is contained once the `vars` argument is typed from the
  spec.
- **Reported recall stays at 2 of 9**, and they are the same two functions.
  `Join.escape/3` moves from `possible_domain_escape` to
  `possible_input_approximate`.
- **The other seven stay `unknown`.**

The nine reproducers in `test/support/omission_fixtures.ex` give the same
results.

The measured gains elsewhere are small and all report-only:

- **One new real omission, found and confirmed by running it.**
  `Ecto.Changeset.apply_changes(%Ecto.Changeset{})` returns `nil`, but the
  spec says `Ecto.Schema.t() | map()`. The root cause is the same as
  `apply_action/2`. It is reported as `possible_domain_escape`, not gated.
- **Two of the four report-only false positives on decimal, plug and ecto
  are removed:** `Decimal.scale/1` and `Ecto.Query.Builder.CTE.escape/2`.
- **18 more obligations are established** (`unknown` to `none`): 13 in
  plug, mostly `Plug.Conn` struct updates, and 5 in ecto.

The measured costs:

- **Fixtures.** Two new false positives on the 25 experiment fixtures.
  - `name/1` returns `nil` from a head clause that the body run itself
    reports as redundant.
  - `display/1` returns `nil` from a `case` branch that cannot be reached
    under the spec domain. The checker does not flag that branch, even in
    `:static` mode.

  The redundancy guard removes `name/1` and cannot remove `display/1`. A
  defensive catch-all is a common real-code shape, and body analysis turns
  it from `domain_escape` into contained evidence.
- **Real code.** On real code the body run added no warning except
  `quoted_type/2`, a true omission: 0 new false positives on the 30 random
  modules (114 functions), and 0 on all of decimal, plug and ecto (297
  slices).
- **Time.** Each slice re-checks the whole module: a median of 3 to 8 ms
  per slice on OSS modules and 4.4 ms on `Enum`. Over the three libraries
  this is 1.7 s of body calls, against 1.2 s for the whole signature
  analysis.

**What body analysis does not solve**, counting the 8 misses (the cause
lists overlap):

- **Top-only returns from callees**, which the spec domain does not reach.
  - Helper insensitivity (3): `Decimal.compare/2`, `cmp/2` and
    `Ecto.Changeset.apply_action/2`. Helpers keep the `:default` domain
    (DESIGN 7 item 1), so a value passed through a private helper or a
    public callee comes back as `dynamic()`.
  - Generic stdlib calls without parametric signatures (4):
    `Plug.Conn.Query.decode/4`, `merge_private/2`, `Ecto.Repo.Assoc.query/4`
    and `Ecto.Repo.Preloader.query/7`. `Enum.map/2`, `Enum.reduce/3`,
    `Enum.into/2` and `Map.new/1` return `dynamic()` whatever the fun or
    the input returns.
- **Input approximation from translation** (primary in 1, secondary in 3).
  `Join.escape/3`: `Macro.t()` (`recursive_cutoff`) and `Macro.Env.t()`
  (`map_key_widened`, `integer_refinement_erased`) make every clause
  `containment_unknown`. Its clause returns (5-tuples) are disjoint from
  the spec, so an exact domain would give a `clause_conflict`. `Decimal.t()`,
  `Plug.Conn.t()` and `Ecto.Changeset.t()` cap three more at
  `possible_input_approximate` even if their returns became precise.
- **Representation and recogniser limits.**
  - Negated struct fields (`merge_private/2`) and improper-list negations
    (`Preloader.query/7`) are not structured components.
  - A list of rows under a spec of `[struct()]` (`Assoc.query/4`) shares
    `[]` with the spec, so it is not disjoint, and a list whose elements
    are lists is not recognised.
  - Pattern parts not bound to a variable keep their pattern type
    (`term()` fields). The spec domain only refines variables, so struct
    clauses of `Decimal.compare/2` still escape.
- **Recursion.** A self-call during inference yields `dynamic()`, so
  recursive clauses stay top-only (`Join.escape/3`, `quoted_type/2`, the
  helper `unextract/3`). Per-clause evidence (DESIGN 3.1 step 7) already
  isolates these clauses, so recursion is never the only blocker.

**What would reopen the decision:**

- an upstream API with call-site-sensitive helper inference, or parametric
  signatures for `Enum` and `Map`;
- a translator that keeps `D_lo` for recursive and struct types;
- a corpus where the body run gates at least 3 confirmed omissions that
  the signature misses, with no confirmed false positive.

| Measure | Signature (product) | Body (spec domain) |
| --- | --- | --- |
| Known omissions gated (`clause_conflict` or SL002 candidate) | 0 of 9 | **1 of 9** (`quoted_type/2`) |
| Known omissions reported (any SL001 or SL002 class) | 2 of 9 | 2 of 9 |
| Reproducers gated / reported | 0 / 2 of 9 | 1 / 2 of 9 |
| Experiment fixtures: detected / false positives (25) | 9 / 0 | 9 / 2 (9 / 1 with the redundancy guard) |
| New warnings on the 30 random modules (114 functions) | n/a | 0 |
| New warnings on all of decimal, plug and ecto (297 functions) | n/a | 1 (`quoted_type/2`, a true omission) |
| Reported functions (SL001 or SL002) on decimal, plug and ecto: true / false positives | 2 / 4 | 3 / 2 |
| Top-only slices on decimal, plug and ecto | 141 | 129 (132 from remote resolution alone) |
| Cost over decimal, plug and ecto | 1.16 s (whole analysis) | +1.67 s of body calls, +0.34 s of default runs |

## Setup

- **Compiler.** The pinned revision `c24c235` in a detached worktree of
  `~/elixir`, with only the `Module.Types.warnings/7` hunk of `b88a257a3`
  (`ls-typespec-tightening`) applied. It applied cleanly: 25 lines added,
  3 removed.

      git -C ~/elixir worktree add --detach $ELIXIR_BODY c24c235
      git -C ~/elixir show b88a257a3 -- lib/elixir/lib/module/types.ex |
        git -C $ELIXIR_BODY apply
      make -C $ELIXIR_BODY compile          # 31 s

  The build reports `1.21.0-dev (c24c235)`. `:elixir_erl.checker_version()`
  is still `:elixir_checker_v10`, and `SpecLint.Compiler.preflight/0`
  accepts it with `body_hook: true`. `~/elixir` was not modified. The
  worktree is kept in the session scratchpad at
  `$SCRATCHPAD/elixir-body`, where `$SCRATCHPAD` is
  `/private/tmp/claude-501/-Users-lukaszsamson-claude-fun-spec-lint/4edd4a29-0707-4a4d-91b9-c1bef7d15467/scratchpad`.
  It is not durable, and the commands above recreate it.
- **Corpora.**
  - decimal, plug and ecto at the pinned revisions, compiled with the
    patched build into a separate `MIX_BUILD_PATH` (`$SCRATCHPAD/oss-body`),
    so the pinned checkouts stay untouched.
  - The fixtures (`test/support/{fixtures,omission_fixtures,experiment_fixtures}.ex`),
    compiled with the patched `elixirc`.
  - `Enum` and `Keyword`, for cost only.
- **Runner.** `bench/body_experiment.exs` runs under the patched `elixir`
  with `-pa _build/test/lib/spec_lint/ebin`, not under `mix run`.
  `bench/corpus/body_run.sh` issues every invocation and writes
  `bench/corpus/reports/body/*.json`:

      ELIXIR_BODY=... SPEC_LINT_OSS=... [SPEC_LINT_OSS_BODY=...] bench/corpus/body_run.sh

- **Selection.** Two runs per library:
  - the modules holding the omissions plus 30 random other modules with
    at least one compared slice, drawn with seed 20260928. That is
    decimal 1 and plug 11 (each library's whole pool), and ecto 18;
  - every module of the library (`*_full`).

  Both runs give the same class changes.
- **Modes.** Each compared slice is classified four times, with the
  existing `SpecLint.Compare.slice/3` and `SpecLint.Evidence.classify/1`:
  - `signature`: the stored `ExCk` signature, as the product sees it;
  - `default`: `warnings/7` with every domain `:default`. The checker runs
    in `:dynamic` mode here and resolves remote calls, which the `:infer`
    pass that writes the chunk skips. This isolates that effect;
  - `body`: `warnings/7` with the target's domain
    `{:dynamic, [dynamic(D_hi_i)]}` of this slice and every other
    definition `:default`. Each call is one slice with the whole tuple
    domain in a fresh checker context (`warnings/7` builds a new context
    per call; only the remote-export cache is shared). The target's
    `local_sigs` entry, compacted as the compiler does before writing the
    chunk, replaces the inferred clauses;
  - `body_guarded`: `body`, except that a slice does not warn when the body
    run reports one of the target's clauses as redundant.
- **Detection.** A function is detected when a slice is a gated SL001
  `clause_conflict` or an SL002 `structured_possible` candidate. The
  prerequisites are those of `bench/experiment.exs`.
- **One environment difference in the `signature` column.**
  `Plug.Conn.get_ssl_data/1` is `unknown` here and `none` in
  `bench/corpus/reports/plug.json`. Under plain `elixir` every OTP
  application is on the code path, so `:ssl.connection_info()` resolves.
  Under `mix run`, Mix prunes the code path, so the remote type is
  unresolved (`term()`). Every other function of decimal, plug and ecto has
  the same signature class as the committed reports.
- **Hook artefact found and corrected.** `warnings/7` returns `local_sigs`
  without the `group_clauses_by_return/1` compaction that `infer/7`
  applies before storing. Uncompacted, `Plug.Conn.Status.code/1` (70
  clauses) passes the 16-clause application cutoff and becomes top-only,
  which is a spurious regression. The runner copies the compaction.

## Recall on the nine known omissions

| Omission | Signature class | Body class | Detected | Why not |
| --- | --- | --- | --- | --- |
| `Decimal.compare/2` | unknown (top-only) | unknown (top-only) | no | Helper insensitivity: the NaN clauses return through the `error/4` macro and the private `handle_error/4`, which is inferred with `dynamic()` arguments, so the clause returns `dynamic()`. The struct-pattern clauses still escape (unbound fields keep `term()`). `Decimal.t()` is input-approximate (`1 \| -1`, `non_neg_integer()`) and would cap the class at `possible_input_approximate`. |
| `Decimal.cmp/2` | unknown (top-only) | unknown (top-only) | no | Helper insensitivity: delegates to `compare/2`, which is analysed under its default domain and returns `dynamic()`. |
| `Plug.Conn.Query.decode/4` | unknown (top-only) | unknown (top-only) | no | Generic stdlib calls: `Map.new/1` and `Enum.reduce/3` return `dynamic()`. The `""` clause and the `is_binary` clause share the argument type `binary()`, so they merge into one clause. |
| `Plug.Conn.merge_private/2` | unknown | unknown | no | `Enum.into/2` is generic, so `private` is `term()`. The extra is a struct whose `private` field is negated, which is not a counted component (representation limit). `Plug.Conn.t()` is input-approximate. |
| `Ecto.Changeset.apply_action/2` | unknown | unknown | no | Helper insensitivity: `apply_changes/1` is analysed under its default domain, so `{:ok, term()}` is a subtraction payload. The same body run on `apply_changes/1` itself finds the `nil` (see below). |
| `Ecto.Query.Builder.Join.escape/3` | possible_domain_escape | possible_input_approximate | no | Input approximation: `Macro.t()` and `Macro.Env.t()` losses make all 10 clauses `containment_unknown`. Nine clause returns are 5-tuples disjoint from the spec (would be `clause_conflict` with an exact domain). The recursive clause is top-only. |
| `Ecto.Query.Builder.quoted_type/2` | possible_domain_escape | **clause_conflict** | **yes** | The literal-atom clause (`is_atom and not is_nil`) returns `:atom`, which is not in `Ecto.Type.primitive()`. The clause is contained once `vars` is `Keyword.t()`. The other stale clauses stay `containment_unknown`. |
| `Ecto.Repo.Assoc.query/4` | unknown (top-only) | unknown (top-only) | no | `Enum.map(rows, fun)` gives `dynamic()` although `fun` is typed (no parametric signature). The `for` clause gives `list(non_empty_list(term(), term()))`, which shares `[]` with `[struct()]`, and its list-of-lists extra is not recognised. |
| `Ecto.Repo.Preloader.query/7` | unknown (top-only) | unknown (top-only) | no | `Enum.map` with an untyped `fun()`, plus the recursive private `unextract/3`, give an improper-list negation extra. |

Gated recall is 0 of 9 before and 1 of 9 after. Reported recall is 2 of 9
before and after. All nine fixture reproducers
(`SpecLint.OmissionFixtures.Cases`) give the same signature class, the
same body class and the same detection as their originals.

The `default` column (not shown) equals `signature` for all nine: remote
resolution alone changes nothing on them.

## False positives

**The 25 experiment fixtures:**

| Mode | Detected | Suppressed | False positive | True negative |
| --- | --- | --- | --- | --- |
| `signature` | 9 | 2 | 0 | 14 |
| `default` | 9 | 2 | 0 | 14 |
| `body` | 9 | 2 | **2** (`name/1`, `display/1`) | 12 |
| `body_guarded` | 9 | 2 | **1** (`display/1`) | 13 |

- **`name/1`** (`def name(a) when is_atom(a)`, then `def name(_), do:
  nil`, spec `atom() -> String.t()`). Under the spec domain the second
  clause is redundant, and the body run says so. Its argument type is
  still `atom()`, so the two clauses merge into
  `(atom()) -> dynamic(binary()) or nil`, and `nil` becomes contained
  structured evidence.
- **`display/1`** (the same catch-all inside a `case`). The checker does
  not report the `_ -> nil` branch as unreachable under
  `dynamic(atom())`, nor under `atom()` in `:static` mode. The guard cannot
  see it.
- **Other class changes are harmless.**
  - `kind/1` and `Secret.new/1` become `none`.
  - `count/1` moves from `possible_domain_escape` to
    `whole_kind_possible`: `1 + dynamic()` still gives `float()`.
  - `wrap/1` becomes `unknown`: the helper call is now a type error under
    the domain.

**Real code.** No new warning appears on the 30 random modules or on the
rest of the three libraries. The only new warning in all 297 slices is
`quoted_type/2`, a true omission.

Every class change was triaged by reading the source:

| Function | Signature → body | Verdict |
| --- | --- | --- |
| `Ecto.Query.Builder.quoted_type/2` | possible_domain_escape → clause_conflict (gated) | True omission (known). `quoted_type(:foo, vars)` returns `:atom`. |
| `Ecto.Changeset.apply_changes/1` | unknown → possible_domain_escape | **New true omission.** `apply_changes(%Ecto.Changeset{})` returns `nil` (run on the pinned ecto), outside `Ecto.Schema.t() \| data` with `data :: map()`. Report-only: the clause escapes because its unbound struct fields keep `term()`. |
| `Ecto.Query.Builder.Join.escape/3` | possible_domain_escape → possible_input_approximate | True omission (known), still report-only. |
| `Decimal.to_integer/1` | possible_domain_escape → possible_input_approximate | False positive kept: a `float()` from arithmetic, the O3 shape. |
| `Ecto.Changeset.field_missing?/2` | possible_domain_escape → possible_input_approximate | False positive kept: the falsy branch of `&&`. |
| `Decimal.scale/1` | possible_domain_escape → none | False positive removed. |
| `Ecto.Query.Builder.CTE.escape/2` | possible_domain_escape → unknown | False positive removed. |
| 13 `Plug.Conn` functions, `Ecto.put_meta/2`, 4 `Ecto.Changeset` functions, 3 `Keyword` functions | unknown → none | The obligation is now established. A struct update of `dynamic(Plug.Conn.t())` keeps the typed fields. |

In the 30 random modules, the only class changes are `Ecto.put_meta/2`
(unknown → none) and `CTE.escape/2` (false positive removed).

**Diagnostic diff** (DESIGN 7 item 3). These are the checker warnings the
spec-domain run adds to the default run. All were read, and none is a bug.

| Corpus | Extra warnings | What they are |
| --- | --- | --- |
| decimal | 0 | |
| plug | 2 on 2 slices | `Plug.Conn.resp/3`: the `nil` body clause cannot match. `Plug.forward/4`: the `{mod, fun}` clause of `do_forward/3` is unused because the spec says `atom()` (a spec narrower than the code). |
| ecto | 8 on 5 slices | Defensive `Builder.error!` clauses that are redundant or can never match under the spec (`CTE.apply/5`, `From.build/5`, `Join.build/10`, `Windows.build/4`), and one tuple pattern in `Builder.escape/5`. |
| Enum, Keyword | 20 on 11 slices | Clauses that belong to the other spec overload: `max/2`, `min/2`, `min_max/2`, `min_max_by/3` and `with_index/2` report "guard will never succeed" or "incompatible default arguments". `Enum.slice/2` has a redundant clause. |
| fixtures | 4 on 4 slices | Redundant clauses (`name/1`, `pick/1`), a constant conditional (`kind/1`), and the badapply in `wrap/1`. |

The guard fires on 7 slices in total, and changes the outcome only on
`name/1`.

## Cost

These are wall-clock times of `warnings/7` calls, from the committed
reports (`totals.cost`). Signature analysis is the Phase 1 runtime of the
whole corpus.

| Corpus | Slices | Body calls total | Median / p90 / max per slice | Default runs | Signature analysis |
| --- | --- | --- | --- | --- | --- |
| fixtures | 37 | 18 ms | 0.45 / 0.68 / 1.3 ms | 7 ms | |
| `Enum` + `Keyword` | 142 | 542 ms | 4.4 / 5.0 / 8.6 ms | 15 ms | |
| decimal (all) | 46 | 345 ms | 7.9 / 8.7 / 11.6 ms | 19 ms | 66 ms |
| plug (all) | 86 | 533 ms | 5.3 / 12.0 / 24.8 ms | 70 ms | 402 ms |
| ecto (all) | 165 | 788 ms | 2.9 / 13.8 / 16.5 ms | 250 ms | 694 ms |

- **One slice costs about one re-check of the whole module.** `warnings/7`
  traverses every definition of the module, not only the target and what
  it reaches. For example, `Ecto.Changeset` costs 32 ms for one default
  run, and its slices cost up to 20 ms each. The per-module cost is
  therefore slices times module size.
- **Whole runs**, including VM start, signature analysis and all
  `warnings/7` calls: decimal 1.2 s, plug 2.3 s, ecto 3.6 s.
- **The stdlib was not run.** At the `Enum` rate of about 4 ms per slice,
  its 1,777 slices would take about 8 s, against 2.7 s for signature
  analysis.
- **Batching** (DESIGN 7 item 4) is not needed at these sizes.

## Minimal compiler API

This is what the experiment needed from the compiler, and what the
current hook lacks.

```elixir
# Capability probe; replaces function_exported?(Module.Types, :warnings, 7).
Module.Types.capabilities() :: %{infer_under_domains: 1, checker: :elixir_checker_v10}

Module.Types.infer_under_domains(module, file, attrs, defs, no_warn_undefined, cache,
  targets :: %{{atom(), arity()} => {:dynamic | :static, [Descr.t()]}}
) :: %{
  version: 1,
  # Per target, in the form stored in ExCk (group_clauses_by_return applied).
  signatures: %{{atom(), arity()} => {:infer, domain, [{[Descr.t()], Descr.t()}]}},
  # Per target and source clause: which signature clause it feeds, and
  # whether it is reachable under the given domain.
  clauses: %{{atom(), arity()} => [%{clause: non_neg_integer(),
                                     signature_clause: non_neg_integer(),
                                     reachability: :reachable | :redundant | :unused}]},
  diagnostics: [{module(), warning :: term(), location :: term()}]
}
```

Contract:

- **Only the targets are checked**, plus the local definitions they reach.
  `local_handler/5` already infers lazily. Today `warnings/7` walks every
  definition, which makes one slice cost one module.
- **One target per call has its own fresh context.** Helpers are inferred
  under `:default`.
- **Signatures come in stored form.** The returned signature is compacted
  as it is when written to `ExCk`, so the SpecLint application copy
  (`apply_infer/2`, 16-clause cutoff) applies unchanged.
- **Reachability is per source clause.** This lets a consumer drop the
  return of a clause the domain makes redundant, instead of blocking the
  slice. It also replaces the stored-domain shadowing approximation
  (DESIGN 3.1 step 7).
- **The capability is versioned separately** from the checker chunk
  version. The hook does not change the chunk.

The `ls-typespec-tightening` hook (`warnings/7`, a domains callback
returning `:default | {mode, [arg_descr]}` and `{warnings, local_sigs}`)
covers the first two points in spirit. Its gaps are these: it returns
uncompacted `local_sigs` with the internal `{kind, info, mapping}` shape,
has no reachability per clause, checks the whole module, and can only be
detected by `function_exported?/3`.

Two things would matter more for recall than this API, and neither is a
hook:

- call-site-sensitive helper inference;
- parametric signatures for `Enum.map/2`, `Enum.reduce/3`, `Enum.into/2`
  and `Map.new/1`.

Together they cover 7 of the 8 misses.
