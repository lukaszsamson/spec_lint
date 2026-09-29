# Compiler internals audit: Elixir 1.20.4 against the 1.21 adapter

Every compiler internal that `SpecLint.Compiler.V121` (qualified for
`c24c235` and `648b2a9`, `audit-648b2a9.md`), `SpecLint.Project` and the
tests depend on, probed on Elixir 1.20.4 for the new adapter
`SpecLint.Compiler.V120` (Milestone 3). Rows 1-25 are the rows of
`audit-648b2a9.md`; rows 26-35 are the encodings the adapters inspect
directly (map fields, key domains, tuple, list and function literals, the
dynamic node, recursive nodes, `term()`) and two checker behaviours the
tests pin per adapter. As in the 648b2a9 audit, a matching interface is not
taken as evidence: each row was probed on 1.20.4, and the output is below.

## The build

| | |
| --- | --- |
| Release | Elixir 1.20.4, the precompiled release for OTP 29 (`asdf install elixir 1.20.4-otp-29`, `~/.asdf/installs/elixir/1.20.4-otp-29`) |
| Revision | `759443e724f55bf58e71c0603644e99058918d52` (tag `v1.20.4`, "Release v1.20.4"); `System.build_info()[:revision]` `759443e`, build date `2026-08-28T10:04:20Z` |
| Adapter id | `1.20.4+759443e` |
| Checker chunk | `elixir_checker_v8` |
| Erlang/OTP | 28.5.0.1 for every run below (the 1.21 builds' OTP, so the comparison isolates the compiler); preflight also passes on 29.0.1 |
| Pinned build digest | `ab40621dc4c1ee7ce26ad192bb3ab0dd65c434816cd2dfb247faff3446e85766` (the same on OTP 28.5.0.1 and 29.0.1) |
| Identity (`identity.exs`) | `code_digest` `cf42510c62e2725d02769af5996c808a8b597351db0d0dceb52ebf8a88febcb8`, `exck_digest` `28bc01cf3075064bdebb88faf653a8ca8decb87c8c1bbd8e24c0e2e28a596d07`, 447 modules |

`v1.20.4` is not an ancestor of either 1.21 revision; it branched from
`main` at `1f19a053c` (2026-05-21). Source blobs of the audited files, 1.20.4
against `c24c235`: `descr.ex` `2e70145e01` / `e0f4174161`, `pattern.ex`
`febf6043d5` / `86ae195cfb`, `types.ex` `74c0754372` / `9394b9c6dd`,
`apply.ex` `9100c9f7a7` / `b56d22a477`, `elixir_erl.erl` `b7f401ba68` /
`ca29a307e2`, `code/typespec.ex` `f04cac439f` / `b87a0547ff`,
`mix/compilers/elixir.ex` `fb835c0e05` / `3ee3e388a4`, `elixir_def.erl`
`2f27fd0782` / `ed1619fcb2`; `parallel_checker.ex` (`7627428d31`) and
`elixir_overridable.erl` (`551342fe97`) are identical. Every audited module
therefore gets its own probe result below; none is assumed from 1.21.

## How the rows were probed

- `bench/corpus/toolchain/audit_probe.exs` prints rows 1-22 and 26-35
  calling `Module.Types.Descr` directly (not through an adapter). It was run
  on the three builds:

      ASDF_ELIXIR_VERSION=1.20.4-otp-29 elixir bench/corpus/toolchain/audit_probe.exs
      ~/elixir/bin/elixir bench/corpus/toolchain/audit_probe.exs          # c24c235
      $UP/bin/elixir bench/corpus/toolchain/audit_probe.exs               # 648b2a9

  Its 1.20.4 output is quoted in the table; where it says "as 1.21" the
  line is identical on `c24c235`. The only line that differs between the
  two 1.21 builds is row 19.
- `SpecLint.Compiler.V120.probe/2` for each of the eleven capability probes
  on 1.20.4: all `:ok`, and `preflight/0` returns `{:ok, ...}` with adapter
  id `1.20.4+759443e`, on OTP 28.5.0.1 and 29.0.1. Under 1.20.4 the 1.21
  adapter's `check_build/2` rejects the version (`{:unsupported_elixir,
  "1.20.4", "~> 1.21.0-dev"}`), and `SpecLint.Compiler.select_adapter/2`
  never pairs it with a v8 chunk.
- The whole test suite under 1.20.4 (STATUS.md, "Milestone 3").

Tests: `test/spec_lint/compiler_probe_test.exs` (CPT),
`compiler_test.exs` (CT), `clause_local_test.exs` (CLT),
`upstream_qualification_test.exs` (UQT), `omissions_test.exs` (OT),
`build_record_test.exs` and the integration `BuildRecordTest` (BRT). Tests
tagged `adapter: V120` or `adapter: V121` run only under that adapter's
compiler; the others run on all three builds.

## Table

"Probe" is the capability probe of `SpecLint.Compiler.Qualification`
that `preflight/0` runs; a failing probe fails preflight (exit 2 in CI).

| # | Item | 1.21 (`c24c235`, `648b2a9`) | 1.20.4 (probe output) | Same? | Probe | Tests |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `Module.Types.Descr` functions the adapter calls | 43 pairs, including `opt_union/2`, `opt_intersection/2`, `opt_difference/2`, `unfold/1`, `recursive/1` | `opt_union/2 opt_intersection/2 opt_difference/2 unfold/1 recursive/1` not exported (`unfold/1` is private); `union/2 intersection/2 difference/2 if_set/1 not_set/0` exported. V120 calls 42 pairs: the 38 shared ones plus `union/2 intersection/2 difference/2 if_set/1` | **different** | `:descr_exports` with each adapter's `required_descr/0` | CPT "a missing function" (both); every probe passes |
| 2 | Bitmap bits: `binary 1, bitstring_no_binary 2, empty_list 4, integer 8, float 16, pid 32, port 64, reference 128` | as listed | `[binary: %{bitmap: 1}, bitstring_no_binary: %{bitmap: 2}, empty_list: %{bitmap: 4}, integer: %{bitmap: 8}, float: %{bitmap: 16}, pid: %{bitmap: 32}, port: %{bitmap: 64}, reference: %{bitmap: 128}]` | same | `:descr_encoding` (`:bitmap`) | CPT "a changed bitmap bit" (on 1.20.4 `:term_expansion` fails with it, row 33) |
| 3 | Atoms `%{atom: {:union \| :negation, :sets}}` | as listed | `{%{atom: {:union, %{ok: []}}}, %{atom: {:negation, %{ok: []}}}}` (difference taken with `difference/2`) | same | `:descr_encoding` (`:atom_union`, `:atom_negation`) | CPT "atoms no longer stored as a union set" |
| 4 | Tuple literals in `bdd_to_dnf/1` lines: `{hash, :closed \| :open, elements}` | as listed | `[{[{-124452592, :closed, [%{atom: {:union, %{ok: []}}}]}], []}]`, `[{[{33514998, :open, [...]}], []}]` (the same hashes as 1.21) | same | `:descr_encoding` (`:closed_tuple`, `:open_tuple`) | CPT "a changed tuple layout" |
| 5 | Map literals: `closed_map/1` input and DNF literal; `open_map()`; `empty_map()` | input `[{atom, {value, optional?}} \| {[kind], value}]`; literal `{hash, tag, [{key, {value, optional?}}]}` | input `[{atom, value} \| {[kind], value}]`, the 1.21 form raises (`expected a map, got: {%{bitmap: 8}, true}`); literal `{hash, :closed \| :open \| [{kind, value}], [{key, value}]}`, see rows 26-27; `open_map` `[{[{61102469, :open, []}], []}]` and `empty_map` `%{map: {-113427502, :closed, []}}` as 1.21 | **different** | `:descr_encoding` (`:closed_map`, `:open_map`) | CPT "a changed map field encoding (the not_set() marker)", "a changed optional flag on fields" (V120); "the optional flag" (V121) |
| 6 | Non-empty list literal `{hash, element, tail}`; `[]` is bit 4 | as listed | `[{[{118414359, %{bitmap: 8}, %{bitmap: 4}}], []}]`; `list(integer())` is `%{list: ..., bitmap: 4}` | same | `:descr_encoding` (`:list`) | every probe passes |
| 7 | `fun()` is `%{fun: {:negation, %{}}}` | as listed | `%{fun: {:negation, %{}}}`; `fun(1)` `%{fun: {:union, %{1 => :bdd_top}}}` | same | `:descr_encoding` (`:fun`) | every probe passes |
| 8 | `dynamic(t)` is `%{dynamic: t}`, `term()` `:term`, `none()` `%{}`; `unfold/1` and recursive nodes | as listed; `unfold/1` expands `term()` and nodes | `{%{dynamic: %{bitmap: 8}}, %{dynamic: :term}, :term, %{}}`; no public `unfold/1`, no `recursive/1`: see rows 31-33 | **different** (no unfold, no nodes) | `:descr_encoding` (`:dynamic`, `:term`, `:none`; V120 `:term_expansion`, `:no_recursive_nodes`) | CPT "dynamic no longer a :dynamic field"; rows 32-33 |
| 9 | Descr semantics: contravariance, optional fields and key domains in `subtype?/2`, gradual bounds, set operations, `to_domain_keys/1`, `atom_fetch/1`, `to_quoted_string/2` with `skip_dynamic_for_indivisible: false` | as listed | contravariance `{true, false}`; bounds `{true, true, true, false}`; `atom_fetch` `{{:finite, [:a, :b]}, {:infinite, []}, :error}`; union commutes `true`; printer `"dynamic(integer())"`; optional fields checked with the 1.20 field form (row 26) | same (with the 1.20 map input) | `:descr_semantics` (V120's `semantic_checks/1`) | CPT "covariant functions", "a changed printer option", "changed gradual bounds", "changed domain keys", "changed atom_fetch/1" (both) |
| 10 | `:elixir_erl.checker_version/0` | `:elixir_checker_v10` | `:elixir_checker_v8` | **different** (expected) | `:checker_version` | CPT "a new chunk version" (per adapter); CT "adapter selection" |
| 11 | `ExCk` contents `{version, %{exports: [{{f, a}, %{sig: sig, ...}}], mode: atom}}` | as listed (Keyword: 50 exports) | `{:elixir_checker_v8, [:exports, :mode], :elixir, 50, %{infer: 50}}` | same shape, other version | `:checker_chunk` | CPT "the ExCk chunk layout" (seven tests, both) |
| 12 | Stored signatures of the standard library | 3,926 exports: 3,867 `:infer`, 59 without a signature | 3,893 exports: 3,834 `:infer`, 59 without | different (another standard library) | covered by the stdlib replay | `reports/elixir-1.20.4/stdlib.spec_lint.json` |
| 13 | `Module.Types.Apply.remote_apply/7`, `Module.Types.stack/7`, `context/0` | exported | `{true, true, true}` | same | `:apply_infer` (entry points) | CPT "a missing entry point" |
| 14 | `apply_infer/2` (private), copied by the adapter | `@max_clauses 16`, returns reduced with `opt_union/2` | the same 62 lines except `Enum.reduce(&union/2)` for `&opt_union/2` (in `apply_infer/2` and `apply_strong/4`); `@max_clauses 16` | **different** (union function only) | `:apply_infer` (V120's copy against `remote_apply/7`: selection, gradual arguments, no clause, 16 and 17 clauses) | CPT "a larger clause cutoff", "a result no longer wrapped in dynamic()"; CT "30 generated clause sets agree" (both) |
| 15 | `remote_apply/5` special cases | 648b2a9 has a precise `:erlang.--/2`, c24c235 the generic one | generic: `{:erlang, :--, [{[list(term()), list(term())], dynamic(list(term()))}]}` | as c24c235 | none needed (changes stored signatures only) | stdlib replay |
| 16 | `Module.Types.warnings/6`, `ParallelChecker.start_link/1`, `stop/1` | exported | `{true, true, true}` | same | `:pattern_checker` | CPT "a checker that no longer reports a contradictory guard" |
| 17 | `Pattern.of_head/8`, `of_guard/5`; diagnostics tagged `Module.Types.Pattern`; `{Module.Types, {:unused_clause, ...}, ...}` | as listed | `{true, true}`; the probe's four definitions give `[{{:g, 1}, 2}, {{:priv, 1}, 7}]` as on 1.21 | same (but see row 35) | `:pattern_checker` | CPT "diagnostics under another module tag", "no longer reports an unused private clause", "a changed pattern entry point arity" |
| 18 | `Code.Typespec.fetch_types/1` kinds; `fetch_specs/1`; `spec_to_quoted/2` | `:type`, `:typep`, `:opaque`, `:nominal` (OTP 28) | `[:opaque, :type, :typep]` for an Erlang module that also has a `-nominal` type: 1.20.4's `fetch_types/1` reads only `:type` and `:opaque` attributes and leaves nominal types out; `fetch_specs/1`, `spec_to_quoted/2` as 1.21 | **different** | `:typespec_kinds` with `nominal_types?/0` (V120: `false`, the nominal type must be left out, not reported as another kind) | CPT "a kind no longer reported" (V121), "nominal types no longer left out", "the running Code.Typespec leaves nominal types out" (V120) |
| 19 | `for ... into:` with a bitstring-or-list collectable | c24c235 `(term(), term()) -> dynamic()`; 648b2a9 `(term(), bitstring()) -> dynamic(bitstring())` (unsound) | `{["term()", "term()"], "dynamic()"}`: no narrowing | as c24c235 | none possible; pinned per revision | UQT "the stored signature and the SpecLint verdict, per qualified revision" (`759443e`: no finding, exit 0); BRT native verdict |
| 20 | `Mix.Compilers.Elixir.read_manifest/1`: `{modules, sources}`, `{[], []}` for an unreadable manifest | manifest version 37 | `{[], []}` for an unreadable path; manifest version 35 (read by the same function) | same interface | `:compile_manifest` | CPT "read_manifest/1"; integration build and coverage tests under 1.20.4 |
| 21 | `System.build_info()[:revision]` and the adapter id | `c24c235`, `648b2a9` | `"759443e"`, `1.20.4+759443e` | different (expected) | `check_build/2` | CT "preflight pins the qualified Elixir revisions" (V120 cases) |
| 22 | `Module.Types.warnings/7` (body hook) | absent | `false` | same | reported as `body_hook: false` | CT "preflight loads Module.Types before probing the body hook" |
| 23 | Debug info read by `SpecLint.Beam` and `SpecLint.Reachability` (`:debug_info_v1`, `:elixir_erl` backend, definition tuples, `:line`, `generated: true`, `from_super: false`) | as listed | `:debug_info` probe `:ok` (`elixir_def.erl` differs in source, `elixir_overridable.erl` is identical) | same | `:debug_info` | CPT ":elixir_erl debug info" (five tests, both) |
| 24 | Content of the pinned compiler modules (`BuildIdentity`) | build digests `ae7d8dc230f5...` (c24c235), `cce56065b567...` (648b2a9) | `ab40621dc4c1...`; all 14 module digests differ from both 1.21 builds (recorded in `V120.qualified_builds/0`), and are the same on OTP 28.5.0.1 and 29.0.1 | different | `:compiler_identity` | CPT "compiler identity" (four tests, both) |
| 25 | Which compiler produced the analysed BEAM files | both 1.21 builds are `1.21.0-dev` with chunk v10: not distinguishable by Mix | `System.version()` differs, so Mix recompiles the project and its dependencies when switching lines; the chunk version differs (v8/v10), so the decoder refuses the other line's chunks (`unsupported_chunk`, exit 2 in CI); the build record now names the checker version and adapter (`{:other_compiler, ...}`, exit 2) | distinguishable | `SpecLint.BuildRecord`, `select_adapter/2`, chunk decoding | `BuildRecordTest` "another compiler line"; integration BRT across 1.20.4 and c24c235 in both directions |
| 26 | Map fields: how a field is optional | `{key, {value, optional?}}` in `closed_map/1` and in the literal | the value carries the `not_set()` marker: `if_set(integer())` is `%{optional: 1, bitmap: 8}`; `closed_map([{:a, if_set(int)}, {:b, int}, {[:binary], atom()}])` has the literal `{129163240, [binary: %{atom: ..., optional: 1}], [a: %{optional: 1, bitmap: 8}, b: %{bitmap: 8}]}` | **different** | `:descr_encoding` (`:optional_marker`, `:closed_map`) | CPT "a changed map field encoding (the not_set() marker)", "a changed optional flag on fields" |
| 27 | Key domains: names and values | kinds as `to_domain_keys/1` names them, `:bitstring_no_binary` among them; domain values stored without a marker | `to_domain_keys(bitstring_no_binary())` is `[:bitstring]` (`to_domain_keys(term())`: `[:atom, :binary, :bitstring, :float, :fun, :integer, :list, :map, :pid, :port, :reference, :tuple]`); domain values carry the marker (`[bitstring: %{optional: 1, bitmap: 8}]`); `closed_map/1` accepts an unknown kind name such as `:bitstring_no_binary` without error, as a separate domain. Printing (Milestone 3 review): `Descr` prints the `:bitstring` domain as `bitstring()`, so `closed_map([], [{[:bitstring_no_binary], integer()}])` prints `%{bitstring() => integer()}` (1.21: `%{(bitstring() and not binary()) => integer()}`) and the spec `%{optional(bitstring()) => atom()}` prints `%{binary() => atom(), bitstring() => atom()}` (1.21: `%{bitstring() => atom()}`); the same string names a different key set on the two lines. Presentation only: the views are equal (`printing_test.exs`, pinned per adapter) | **different** | `:descr_encoding` (`:bitstring_domain`, `:closed_map`) | CPT "the bitstring key domain renamed" |
| 28 | Tuple literal as `DescrWalk` reads it (closed tuples hashed negatively, elements in order) | as row 4 | as row 4 | same | `:descr_encoding` (`:closed_tuple`, `:open_tuple`) | CPT "a changed tuple layout" |
| 29 | Non-empty list literal as `DescrWalk` reads it | as row 6 | as row 6 | same | `:descr_encoding` (`:list`) | every probe passes |
| 30 | Function part as `DescrWalk` reads it: only `fun()` is a whole kind, any other function type is `{:unknown, :fun, :shape}` | as row 7 | as row 7 | same | `:descr_encoding` (`:fun`) | every probe passes |
| 31 | The dynamic node and its bounds | `upper_bound(dynamic())` is `:term`, expanded by `unfold/1` | `upper_bound(dynamic())` is `:term`, which `DescrWalk` expands through V120's `expand/1` (row 33) | same layout, other expansion | `:descr_encoding` (`:dynamic`), `:descr_semantics` (`:gradual_bounds`) | every probe passes |
| 32 | Recursive nodes | `{reference, state, generator}` from `recursive/1`, unfolded by `unfold/1` (inference produces none) | `unfold/1` and `recursive/1` exported: `{false, false}`; no node layout exists. `V120.recursive_types?/0` is `false` and `recursive_node?/1` is always `false` | **different** (absent) | `:descr_encoding` (`:no_recursive_nodes`: a `Descr` exporting `recursive/1` or `unfold/1` fails preflight) | CPT "recursive nodes appear" (V120), "a changed recursive node layout" (V121); CT "is plain data on a line without recursive nodes" |
| 33 | `term()` expansion | `unfold(term())` has the kinds `[:atom, :bitmap, :fun, :list, :map, :tuple]` | the union of the kinds' top types (`bitstring, empty_list, integer, float, pid, port, reference, atom, tuple, open_map, non_empty_list(term, term), fun`) has the same kinds and `equal?/2` to `term()`: `{[:atom, :bitmap, :fun, :list, :map, :tuple], true}` | same result, built by the adapter | `:descr_encoding` (`:term_expansion`) | CPT "term() is no longer the union of its kinds' top types" (V120) |
| 34 | A source clause that always raises, in the stored signature (`def idx(:a), do: raise(...)` then `def idx(:b), do: {:error, :b}`) | dropped: `[(:b) -> {:error, :b}]` | kept as `(:a) -> none()`: `[{[":a"], "none()"}, {[":b"], "{:error, :b}"}]`, so later clauses shift by one stored index | **different** | none (inference on user code); pinned per adapter | CLT "the reported clause is the stored signature clause" (clause 0 on 1.21, clause 1 on 1.20.4) |
| 35 | A compound impossible guard (`when is_integer(x) and is_atom(x)` on `:b = x`) | the checker reports nothing, so SpecLint's guard witness search blocks the clause (`guard_unproven`) | the checker warns "this guard will never succeed" (line 4 of the probe); SpecLint's re-run of the pattern checker reports it, so `clause_reachable` is blocked by a compiler diagnostic | **different** (1.20.4 sees more) | `:pattern_checker` (unchanged) | CLT "compound impossible guards cannot qualify clause conflicts" (per adapter) |

## Rows that differ, and what the adapter does about each

- **Rows 1, 14 (set operations).** V120 calls `union/2`, `intersection/2`
  and `difference/2`; V121 `opt_union/2` and friends. Both are called
  through `:erlang.apply/3`, so neither compiler's xref, nor Dialyzer,
  sees a call to a function its `Descr` lacks. The `apply_infer/2` copies
  differ in that function only.
- **Rows 5, 26, 27 (map encoding).** `V120.closed_map/2` writes an optional
  field as `if_set(value)` and renames the `:bitstring_no_binary` domain
  to `:bitstring`; `V120.map_view/1` and `key_kinds/1` translate back and
  remove the marker from every value they hand out, so no `:optional` part
  reaches the rest of SpecLint. Row 27's last observation matters: a
  domain named the 1.21 way is accepted silently by 1.20.4 and would be a
  different (wrong) type; `:bitstring_domain` checks the name.
- **Rows 8, 31-33 (no `unfold/1`, no recursive nodes).** V120 expands
  `term()` itself (`expand/1`, computed once per VM from the running
  `Descr` and checked equal to `term()` at preflight) and reports
  `recursive_types: false` in its capabilities. SpecLint's translator never
  builds a recursive descr on either line: recursive typespecs are cut off
  at the depth budget with `recursive_cutoff`, so there is no loss specific
  to 1.20 (DESIGN.md section 6).
- **Row 18 (nominal types).** On 1.20.4 a remote reference to an Erlang
  `-nominal` type is not found and translates as `unresolved_remote_type`
  instead of `nominal_boundary`: the same bounds (`term()` above, `none()`
  below), another loss label, and `expand_opaque: true` cannot expand it.
  Elixir itself has no `@nominal` on either line, and no slice of the
  fifteen 1.21 reports (`reports/m1_review/`, `ledger.slices.loss_kinds`)
  records `nominal_boundary`, so the corpora cannot show this difference.
- **Rows 10, 11, 21, 24, 25.** Expected differences of another release:
  another chunk version, revision and build digest. They make artifacts of
  one line unreadable by the other adapter, and the build record names the
  line, so cross-line artifacts fail closed (row 25).
- **Rows 34, 35 (inference and the checker).** The stored clause list and
  the checker's guard diagnostics differ; both are pinned per adapter in
  the tests, and the corpus comparison (`reports/elixir-1.20.4/README.md`)
  triages every gate they change.
- **Row 12.** Another standard library; its report is part of the replay.
