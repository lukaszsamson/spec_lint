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

Not a bug:
- **Maps whose keys follow an `optional(any)`.** Such map types
  (`Calendar.time()`, `Ecto.Schema.t()`) translate with the later keys
  shadowed. This matches Dialyzer's `erl_types:map_from_form/6`. It is
  Dialyzer-faithful but not what the spec author intended; worth a note in
  the translation docs.
- **Spec gaps outside function returns.** Plug's `@type state` omits
  `:set_upgrade`, which `before_send` callbacks can observe. That is a spec
  gap in plug, but no return-based rule can see it.
