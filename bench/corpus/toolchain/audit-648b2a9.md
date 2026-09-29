# Compiler internals audit: c24c235 against upstream 648b2a9

Every compiler internal that `SpecLint.Compiler.V121`, `SpecLint.Project` and
the tests depend on, compared between the fork revision SpecLint was built on
(`c24c235`) and upstream `648b2a9`. A matching checker chunk version is not
taken as evidence: each row has a probe, run on both builds, and a test.

## The two revisions

Both descend from upstream `25fa6682c` ("Cache common indentation in
Inspect.Algebra (#15947)").

- `c24c235` (`c24c23538d521d25edd6a9a7a66fc5206caab70e`) adds one fork
  commit, "Fix incorrect narrowing in mixed type for into"
  (`lib/elixir/lib/module/types/expr.ex`), which is not upstream.
- `648b2a9` (`648b2a94934664cfd2c788348d02d799c68faa69`, upstream `main` on
  2026-09-27) adds two upstream commits: `434dbfec3` (an `Inspect.Algebra`
  typespec) and `648b2a9` "Preserve left element types in list subtraction
  (#15808)" (a new `remote_apply/5` clause for `:erlang.--/2` in
  `lib/elixir/lib/module/types/apply.ex`).

`git diff c24c235 648b2a9 -- lib/` touches four files: `inspect/algebra.ex`,
`module/types/apply.ex`, `module/types/expr.ex` and a test. Source blob
hashes of the other audited files are identical in both trees:
`descr.ex` `e0f4174161`, `pattern.ex` `86ae195cfb`, `types.ex` `9394b9c6dd`,
`elixir_erl.erl` `ca29a307e2`, `code/typespec.ex` `b87a0547ff`,
`mix/compilers/elixir.ex` `3ee3e388a4`, `parallel_checker.ex` `7627428d31`.
At the BEAM level (`:beam_lib.md5/1`), `Module.Types.Descr`, `Module.Types`,
`Module.Types.Pattern`, `Module.ParallelChecker`, `:elixir_erl`,
`Code.Typespec` and `Mix.Compilers.Elixir` are identical; `Module.Types.Apply`
and `Module.Types.Expr` differ.

Same source is not taken as same behaviour either: the probes below run
against each build, and the full test suite passes on both (STATUS.md,
"Milestone 2").

## Table

"Probe" is the `SpecLint.Compiler.V121` capability probe that `preflight/0`
runs (`capability_probes/0`); a failing probe fails preflight, which is exit 2
in CI. Tests are in `test/spec_lint/compiler_probe_test.exs` (CPT),
`compiler_test.exs` (CT), `coverage_test.exs` and
`upstream_qualification_test.exs` (UQT). Every test runs under both
compilers.

| # | Item | c24c235 | 648b2a9 | Same? | Probe | Tests |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `Module.Types.Descr` functions the adapter calls (39): `none/0 term/0 dynamic/0,1 atom/0,1 integer/0 float/0 binary/0 bitstring/0 bitstring_no_binary/0 pid/0 port/0 reference/0 boolean/0 empty_list/0 list/1 non_empty_list/2 tuple/0,1 open_tuple/1 empty_map/0 open_map/0 closed_map/1 fun/0,1,2 opt_union/2 opt_intersection/2 opt_difference/2 subtype?/2 disjoint?/2 empty?/1 equal?/2 gradual?/1 upper_bound/1 lower_bound/1 to_quoted_string/2 atom_fetch/1 to_domain_keys/1 bdd_to_dnf/1 unfold/1` | all exported | all exported (same source) | same | `:descr_exports` | CPT "Module.Types.Descr a missing function"; CPT "every probe passes" |
| 2 | Bitmap encoding: `binary 0b1, bitstring_no_binary 0b10, empty_list 0b100, integer 0b1000, float 0b10000, pid 0b100000, port 0b1000000, reference 0b10000000` (read by `components/1`) | as listed | as listed | same | `:descr_encoding` (`:bitmap`) | CPT "a changed bitmap bit" |
| 3 | Atom encoding `%{atom: {:union \| :negation, :sets}}` | as listed | as listed | same | `:descr_encoding` (`:atom_union`, `:atom_negation`) | CPT "every probe passes" |
| 4 | Tuple literals in `bdd_to_dnf/1` lines: `{hash, :closed \| :open, elements}` | as listed | as listed | same | `:descr_encoding` (`:closed_tuple`, `:open_tuple`) | CPT "a changed tuple layout" |
| 5 | Map literals: `closed_map/1` input `[{atom, {value, optional?}} \| {[kind], value}]`; DNF literal `{hash, :closed \| :open \| [{kind, value}], [{key, {value, optional?}}]}`; `open_map()` is `{_, :open, []}` | as listed | as listed | same | `:descr_encoding` (`:closed_map`, `:open_map`) | CPT "a changed map field encoding (the optional flag)" |
| 6 | Non-empty list literal `{hash, element, tail}`; `[]` is bitmap bit `0b100` | as listed | as listed | same | `:descr_encoding` (`:list`, `:bitmap`) | CPT "every probe passes" |
| 7 | `fun()` is `%{fun: {:negation, %{}}}` (read as the whole kind) | as listed | as listed | same | `:descr_encoding` (`:fun`) | CPT "every probe passes" |
| 8 | `dynamic(t)` is `%{dynamic: t}`, `term()` is `:term`, `none()` is `%{}`, `unfold/1` is the identity on non-recursive terms (read by `canonical/1`) | as listed | as listed | same | `:descr_encoding` (`:dynamic`, `:term`, `:none`, `:unfold`) | CT "canonical/1"; CPT "every probe passes" |
| 9 | Descr semantics: function contravariance, optional fields and key domains in `subtype?/2`, gradual bounds, set operations, `to_domain_keys/1`, `atom_fetch/1`, `to_quoted_string/2` with `skip_dynamic_for_indivisible: false` | as listed | as listed | same | `:descr_semantics` | CPT "changed semantics: covariant functions", "a changed printer option"; CT "to_string/1 normal form" |
| 10 | `:elixir_erl.checker_version/0` | `:elixir_checker_v10` | `:elixir_checker_v10` | same | `:checker_version` | CPT ":elixir_erl.checker_version/0 missing", "a new chunk version"; CT "checker chunk decoding" |
| 11 | `ExCk` contents: `{version, %{exports: [{{f, a}, %{sig: {:infer \| :strong, domain, [{args, return}]}, ...}}], mode: atom}}`, `length(args) == a` | as listed (Keyword: 50 exports) | as listed (Keyword: 50 exports) | same | `:checker_chunk` (decodes the chunk of `Keyword`'s BEAM) | CPT "the ExCk chunk layout" (renamed key, clause shape, exports as a map, no chunk) |
| 12 | Stored signatures of the standard library (3,926 exports compared as decoded terms) | | 3 differ: `URI.to_string/1` (a wider domain), `IEx.Autocomplete.exports/1` (a narrower return, `list({atom(), integer()})`), both from the precise `--`; `Logger.Backends.Console.handle_info/2` (another term, semantically equal) | different | covered by the stdlib replay (no report change) | UQT "only the adapter and the BEAM identities differ" |
| 13 | `Module.Types.Apply.remote_apply/7`, with `Module.Types.stack/7` and `Module.Types.context/0` to call it | exported | exported | same | `:apply_infer` (entry points) | CPT "a missing entry point" |
| 14 | `apply_infer/2` (private) copied by the adapter: `@max_clauses 16`, clause selection by `zip_not_disjoint?/2`, reverse accumulation, `dynamic()` wrap, `dynamic()` above the cutoff | as listed | source of `apply_infer/2`..`zip_not_disjoint?/2` (62 lines) identical; `@max_clauses 16` | same | `:apply_infer` (the copy against `remote_apply/7` on selection, gradual arguments, no applicable clause, 16 and 17 clauses) | CPT "a larger clause cutoff", "a result no longer wrapped in dynamic()"; CT "differential: apply_infer/2 against the compiler" (30 generated sets) |
| 15 | `remote_apply/5` special cases (inference of callers, not the copy) | `:erlang.--/2` generic | `:erlang.--/2` returns `list(element of left)` | different (precision) | none needed: changes stored signatures only, measured by the replay | UQT replay tests |
| 16 | `Module.Types.warnings/6` `(module, file, attrs, defs, no_warn_undefined, cache)` and `Module.ParallelChecker.start_link/1`, `stop/1` | exported | exported | same | `:pattern_checker` | CPT "a checker that no longer reports a contradictory guard" |
| 17 | `Module.Types.Pattern.of_head/8`, `of_guard/5`; pattern and guard diagnostics tagged `Module.Types.Pattern`; a contradictory guard reported, a live guard not | as listed | as listed | same | `:pattern_checker` (runs the checker on two fixed definitions) | CPT "diagnostics under another module tag", "a changed pattern entry point arity"; `ReachabilityFailureTest` |
| 18 | `Code.Typespec.fetch_types/1` kinds `:type`, `:typep`, `:opaque`, `:nominal` (OTP 28) as `{kind, {name, ast, args}}` | as listed | as listed | same | `:typespec_kinds` (an Erlang module with one type of each kind, compiled in memory) | CPT "a kind no longer reported" |
| 19 | Type checking of `for ... into: into` when `into` may be a bitstring or a list | fork fix: the body is not restricted, variables are not narrowed | the body is expected to be a bitstring: a warning when it cannot be, and a variable used as the body is narrowed to `bitstring()`, including in the stored signature | **different: unsound on 648b2a9** | none possible at preflight (a property of inference on user code); pinned per revision | UQT "the stored signature and the SpecLint verdict, per qualified revision" |
| 20 | `Mix.Compilers.Elixir.read_manifest/1`: `{modules, sources}` for manifest version 37, `{[], []}` for an unreadable one | as listed | as listed | same | `:compile_manifest` | CPT "Mix.Compilers.Elixir.read_manifest/1"; `CoverageTest` "a readable empty manifest takes precedence over a stale .app module list" |
| 21 | `System.build_info()[:revision]` (the qualification key) and the adapter id | `c24c235`, `1.21.0-dev+c24c235` | `648b2a9`, `1.21.0-dev+648b2a9` | different (expected) | `check_build/2` (not a probe: it selects the qualification) | CPT "the qualified revisions ..."; CT "preflight pins the qualified Elixir revisions" |
| 22 | `Module.Types.warnings/7` (the body hook of the body experiment) | absent | absent | same | reported as `body_hook: false` | CT "preflight loads Module.Types before probing the body hook" |

## Row 19: an upstream soundness defect

On `648b2a9`,

```elixir
def f(flag, value) do
  into = if flag, do: [], else: ""
  _ = for _ <- [1], do: value, into: into
  value
end
```

is stored as `(term(), bitstring()) -> dynamic(bitstring())`, but
`f(true, :ok)` returns `:ok`. With `@spec f(boolean(), atom()) :: atom()`
SpecLint reports a gating SL003 (`spec_domain_rejected`) and CI exits 1: a
false positive caused by the compiler. On `c24c235` the stored signature is
`(term(), term()) -> dynamic()` and the run is clean. The fork commit
`c24c23538` fixes it and is not upstream. None of the fifteen corpora is
affected: no stored signature of their own applications differs between the
two compilers except the 33 semantically equal ones in Phoenix LiveView
(below). This is recorded in `UPSTREAM_BUGS.txt` and as a known limitation
of the 648b2a9 qualification.

## Stored signatures of the corpora

Owned applications of the fourteen OSS corpora, built with each compiler
(same sources, same dependencies), compared export by export as decoded
`ExCk` terms: identical except Phoenix LiveView, where 33 functions
(`Phoenix.LiveView.Utils.valid_destination!/2` and 32
`Phoenix.LiveViewTest.Support.Router.Helpers.*_url` functions, all calling
`URI.to_string/1`) are different terms that are semantically equal clause by
clause (`Descr.equal?/2` on every argument and return). BEAM code differs
only in modules that also differ between two builds with the same compiler
(21 in Phoenix LiveView, 3 in Ash, 1 in Nx): nondeterministic compilation,
checked by rebuilding them with `c24c235`.
