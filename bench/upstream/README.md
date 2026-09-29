# Upstream submission package (Milestone 6 preparation)

Nine items for a discussion with the Elixir maintainers, each with a
standalone reproducer, expected versus actual output and a draft issue text.
**Nothing has been filed, posted or sent.** Submission is a separate action
for a human; start with [CHECKLIST.md](CHECKLIST.md), which also covers the
AI-use policy in Elixir's `CONTRIBUTING.md`.

Findings come from `UPSTREAM_BUGS.txt`, `bench/corpus/compiler_counterexamples/`,
`bench/clause_mapping/`, `bench/corpus/reports/phase4/absinthe.profile.md`
and `EXPERIMENTS.md` ("Minimal compiler API"). None of them depends on
SpecLint; a reproducer needs only an Elixir build.

## Verdicts

Every reproducer was run on the three builds below; the full output of each
run is in `results/BUILD/ITEM.txt`. "Reproduces" is the reproducer's own
verdict line, computed from the compiler's output, not a manual reading.

- **upstream**: unmodified Elixir 1.21.0-dev `648b2a9`, OTP 28 (checkout
  built with `bench/corpus/toolchain/build_elixir.sh`, no tracked file
  modified).
- **fork**: Elixir 1.21.0-dev `c24c235`, OTP 28 (the qualified fork, which
  fixes `for_into_narrowing`).
- **1.20.4**: Elixir 1.20.4, OTP 29 (informational).

| # | Item | Kind | upstream 648b2a9 | fork c24c235 | 1.20.4 | File as |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | [helper_insensitivity](helper_insensitivity/) | inference precision | **reproduces** | reproduces | reproduces | discussion |
| 2 | [enum_map_result](enum_map_result/) | inference precision | **reproduces** | reproduces | reproduces | discussion |
| 3 | [list_tl](list_tl/) | algebra bug (latent) | **reproduces** | reproduces | n/a (API differs) | issue or PR with test |
| 4 | [for_into_narrowing](for_into_narrowing/) | soundness bug, false warnings | **reproduces** | does not reproduce (fixed by fork commit c24c23538) | does not reproduce | issue, patch in `fix.patch` |
| 5 | [fun_printing](fun_printing/) | printer / algebra inconsistency | **reproduces** | reproduces | reproduces | question |
| 6 | [map_top_printing](map_top_printing/) | printer presentation | **reproduces** | reproduces | reproduces | issue (small) |
| 7 | [printer_load_per_map](printer_load_per_map/) | printer performance | **reproduces** | reproduces | n/a (constructors differ) | performance note |
| 8 | [subpatterns_leak](subpatterns_leak/) | inference determinism (sound) | **reproduces** | reproduces | reproduces | issue or question |
| 9 | [checker_chunk_api](checker_chunk_api/) | feature request | gap exists | gap exists | gap exists | discussion first |

**Do not file: none.** All nine drafts reproduce on upstream `648b2a9`.
Items that reproduce only on the fork: none. Items that do not reproduce on
upstream: none. The only build-dependent result is item 4, which upstream
has and the fork does not. This is a snapshot of `648b2a9`; the checklist
requires a re-run on current `main` before filing, and a draft that no
longer reproduces there must be marked "do not file".

## What each item claims

Precise claims, so nothing is filed as stronger than it is.

1. **helper_insensitivity.** A literal argument passed to a private helper
   that returns it comes back as `dynamic()`; the inlined body keeps
   `{:error, :nan}`. A `+ 1` on the result is not warned. Sound
   over-approximation, not a soundness bug.
2. **enum_map_result.** `Enum.map/2` returns `dynamic()`; the same
   comprehension returns `dynamic(list({term(), :tag}))`. Only `Enum.map/2`
   has a paired probe.
3. **list_tl.** `list_tl(non_empty_list(atom()) and not non_empty_list(:y))`
   excludes `[:y]`, an achievable tail. No source-level trigger known.
4. **for_into_narrowing.** `for ... into:` with a list-or-bitstring collectable
   requires a bitstring body: two false warnings and a stored domain
   `bitstring()` for an argument accepted at runtime. Unsound signature.
5. **fun_printing.** `fun(2)` and the `(none(), none() -> term())` arrow print
   identically, are not `equal?`, and only one subtype direction holds.
6. **map_top_printing.** A closed map equal to `open_map()` prints as a long
   literal.
7. **printer_load_per_map.** Every print of a struct-shaped map does a module
   load attempt; for an absent module a failed load per print, whose cost
   grows with the code path.
8. **subpatterns_leak.** An unrelated earlier list pattern widens a later
   function's stored clause domain (`term()` instead of `not list`).
9. **checker_chunk_api.** Stored clauses carry no source-clause mapping and
   no reachability; the chunk has only `sig`.

## Running

```sh
elixir bench/upstream/helper_insensitivity/repro.exs      # one item, Elixir on PATH
bench/upstream/run_all.sh                                   # all items, Elixir on PATH
bench/upstream/run_all.sh /path/to/build/bin/elixir LABEL   # a given build
ASDF_ELIXIR_VERSION=1.20.4-otp-29 bench/upstream/run_all.sh elixir elixir-1.20.4
```

Each `repro.exs` prints the build (`System.build_info()`), the observations
and a last line `VERDICT: reproduces | does not reproduce | not applicable
(...)`; it exits 0 when it printed a verdict and 2 if the script itself
failed. The upstream build used here is a clean build of `648b2a9`;
rebuild one with `bench/corpus/toolchain/build_elixir.sh
648b2a94934664cfd2c788348d02d799c68faa69 "$UPSTREAM_ELIXIR"` and run
`bench/upstream/run_all.sh "$UPSTREAM_ELIXIR/bin/elixir" upstream-648b2a9`.
The Milestone 5 review re-ran every reproducer on a fresh build made that
way (release campaign 1's `648b2a9` toolchain): all nine verdict lines
equal `results/upstream-648b2a9/`.

## Layout

```
README.md            this index
CHECKLIST.md         what a human must do before filing
run_all.sh           runs every reproducer against one build
results/BUILD/       full reproducer output per build (upstream-648b2a9, fork-c24c235, elixir-1.20.4)
ITEM/repro.exs       standalone reproducer
ITEM/README.md       expected vs actual, provenance, caveats
ITEM/issue.md        draft issue text (banner says NOT FILED)
for_into_narrowing/fix.patch   the fork's fix as a diff (applies to 648b2a9)
printer_load_per_map/absinthe.profile.md   the printer profile, copied
```

## Not in this package

- The patched-hook discrepancy (`UPSTREAM_BUGS.txt` item 3) is not upstream
  material: it needs investigation of the fork's domain hook first.
- Item 10 of `UPSTREAM_BUGS.txt` (findings that did not reproduce) and the
  library typespec bugs (item 5: Oban, Ash, Absinthe, Req) are separate
  reports to other projects and are out of scope for Milestone 6.
- No SpecLint code, test or documentation was changed by this package.
