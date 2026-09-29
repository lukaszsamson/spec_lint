# Fifteen-corpus replay under upstream Elixir 648b2a9

The Milestone 1 review replay (`../m1_review/`, fork revision `c24c235`)
repeated with the same tool code under unmodified upstream Elixir
`648b2a94934664cfd2c788348d02d799c68faa69`
(`../../toolchain/upstream-1.21-648b2a9.md`). Every OSS corpus was
recompiled with the upstream compiler into a separate build path; the
stdlib corpus is the upstream build's own `lib/*/ebin`. These are regression
corpora, not fresh holdouts.

## Tool revision

The reports were produced from the uncommitted Milestone 2 working tree,
so every `*.provenance.json` records `"tool": {"revision": "63618c2...",
"dirty": true}`. `63618c2` is not the tool that ran: its adapter does not
qualify 648b2a9 and fails preflight (exit 2) under it. The tool is
identified by `source_sha256`
`4dd50973e4faa2df518fbcfb9c0c212c6869d3d7f83871afa634031bba05ca53`, which
`provenance.sh` computes to the same value on a clean checkout of commit
`41f56c3` ("Milestone 2: qualify upstream Elixir 648b2a9"). To repeat the
runs, check out `41f56c3`. Later commits (the Milestone 2 review) change
the report format: `beams` entries gain an `exck` digest and reports an
`artifacts` object, so compare their reports with `compare_replay.sh`, not
byte for byte.

## Regenerate

`$UP` is a build from `bench/corpus/toolchain/build_elixir.sh`, `$BUILD` a
new directory for the corpus builds, `$ORIGINAL_OSS` and `$EXPANSION_OSS`
the checkouts of `bench/corpus/README.md` and `expansion.json` with their
dependencies fetched (repository URLs and a checkout snippet are in
`bench/corpus/README.md`, "Corpora").

```sh
export PATH=$UP/bin:$PATH MIX_BUILD_PATH=/path/to/spec_lint-build-648b2a9/test
export ELIXIR_DIR=$UP SPEC_LINT_COMPILER_REPO=$UP SPEC_LINT_CORPUS_BUILD=$BUILD
export SPEC_LINT_CORPUS_MANIFEST=$PWD/bench/corpus/toolchain/upstream-648b2a9.json
export SPEC_LINT_CORPUS_OUT=$PWD/bench/corpus/reports/upstream-648b2a9 SPEC_LINT_PRODUCT_ONLY=1

SPEC_LINT_OSS=$ORIGINAL_OSS bench/corpus/toolchain/compile_corpora.sh \
  jason decimal nimble_options mime plug ecto
SPEC_LINT_OSS=$EXPANSION_OSS bench/corpus/toolchain/compile_corpora.sh \
  req broadway oban phoenix_live_view ash nx absinthe tesla

SPEC_LINT_OSS=$ORIGINAL_OSS bench/corpus/run.sh stdlib jason decimal nimble_options mime plug ecto
SPEC_LINT_OSS=$EXPANSION_OSS bench/corpus/run.sh req broadway oban phoenix_live_view ash nx absinthe tesla
(cd bench/corpus/reports && ../compare_replay.sh upstream-648b2a9 m1_review)
```

### Verify a regeneration

A regeneration in other directories is not byte-identical to the committed
files, and is not expected to be. BEAM files record the directory they
were built in (debug info, and literals of `use` macros quoted with
`location: :keep`), so the `beams` md5 values of the stdlib and of any
corpus with such modules (12 stdlib modules, `Jason.Decoder.Unescape`), the
artifact `sha256` values in the provenance files and
`loaded_module_types_sha256` change with the build path. Compare instead:

```sh
(cd bench/corpus/reports && ../compare_replay.sh NEW upstream-648b2a9)
```

`differing_report_keys` must list only `beams` (and, with a tool later
than `41f56c3`, `artifacts`), with identical ledgers, findings, gates and
fingerprints. The path-independent compiler identity is
`toolchain.identity` in provenance files written by the current
`provenance.sh` (`identity.exs`: `code_digest`, `exck_digest`); check it
against `../../toolchain/upstream-1.21-648b2a9.md`. The committed provenance
files predate that field.

The runs used Erlang/OTP 28.5.0.1 (`ASDF_ERLANG_VERSION=28.5.0.1`), one
corpus at a time. The reports were produced with the clean-clone build of
`build_elixir.sh`; the corpora were compiled with a worktree build of the
same revision whose identity (`identity.exs`) is identical. The worktree is
not the recorded compiler because another process added untracked files to
it after the build. `summary.json` is the output of `compare_replay.sh`
against `../m1_review/` with notes added.

## Results

All fifteen runs are complete, with the same exit codes as `../m1_review/`
(Ash, Oban and Absinthe exit 1 on gates; the rest exit 0): 4,204 compared
slices, 63 findings, 9 gates. For every corpus the report equals the
`c24c235` report except two keys:

- `adapter`: `1.21.0-dev+648b2a9` instead of `1.21.0-dev+c24c235`;
- `beams`: the paths of the recompiled corpora (`$BUILD/NAME/lib/...`
  instead of `_build/test/lib/...`) and 40 BEAM md5 values.

Ledgers (coverage, translation and obligation counts), findings with their
evidence and rendered details, fingerprints, gate decisions, completion and
configuration are identical. No gate changed, so there is no gate to triage. Against
`../m1/` the differences are exactly those of `../m1_review/` against
`../m1/` (13 fingerprints changed by the Milestone 1 review fixes, none by
the compiler).

The 40 differing md5 values, each checked:

| Corpus | Modules | Cause |
| --- | --- | --- |
| stdlib | 12: `Agent`, `Application`, `DynamicSupervisor`, `GenEvent`, `GenServer`, `IO`, `Module`, `Supervisor`, `Task`, `Mix.Tasks.Escript.Build`, `Mix.Tasks.Help`, `Mix.Tasks.Source` | literals that record the build directory; equal with the build root replaced |
| stdlib | `System` | build revision and date |
| stdlib | `Module.Types.Apply`, `Module.Types.Expr` | source changed between the revisions |
| phoenix_live_view | 21 (`Phoenix.Component` and 20 test-support LiveViews) | nondeterministic compilation: they also differ between two builds with `c24c235` |
| ash | 3 (`Ash.Test.Support.PolicyField.*`) | nondeterministic compilation (literal maps), as above |
| nx | `Nx.Defn.Kernel` | nondeterministic compilation (a keyword literal), as above |

Stored signatures, compared as decoded `ExCk` terms between the `c24c235`
and `648b2a9` builds:

- stdlib: 3 of 3,926 exports differ. *Correction (Milestone 5,
  `../release-1/README.md`): a fresh `build_elixir.sh` build of `c24c235`
  has the same `URI` and `Logger.Backends.Console` chunks as `648b2a9`;
  those two differences came from the `~/elixir` build, not from the
  compiler change. Only `IEx.Autocomplete.exports/1` does.* `URI.to_string/1` (a wider domain) and
  `IEx.Autocomplete.exports/1` (a narrower return), from the more precise
  `:erlang.--/2`; `Logger.Backends.Console.handle_info/2` is semantically
  equal. `URI.to_string/1` stays top-only (`dynamic()` return) and the
  other two have no spec, so no report changes.
- OSS corpora: identical, except 33 Phoenix LiveView functions that call
  `URI.to_string/1`, whose terms differ but are semantically equal clause
  by clause.

The one compiler difference that changes SpecLint's verdict, the `for ...
into:` narrowing of 648b2a9 (`../../toolchain/audit-648b2a9.md`, row 19),
does not occur in these corpora.

These expectations are asserted by
`test/spec_lint/upstream_qualification_test.exs`.

## Absinthe timing

Wall time of the whole `run.sh absinthe` invocation (provenance hashing,
the tool compile check and the product run) under 648b2a9: 65.9 s and
70.2 s in two runs, one corpus at a time. `../m1_review/` measured the
product run alone at 73-75 s under `c24c235`; no slowdown from the
upstream compiler is visible in these samples.
