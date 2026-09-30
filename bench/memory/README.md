# Module-result retention experiment (M8)

This is a research experiment, not an adopted change to SpecLint.Run or a
full-product benchmark. `retention.exs` analyses the same 468 frozen Absinthe
BEAMs, classifies every compared slice, and creates the same 453 inventory
entries. One mode keeps each full analysis result and evidence map; the
other retains only inventory entries. Both use the same shared type cache,
which is deleted before a final GC and process-memory sample. No calls to
rules, reachability, baseline reconciliation or the reporters are included.

Inputs: the exact 1.20.4 compiler and Absinthe artifact set from
`../corpus/reports/hardening-2/1.20.4/absinthe.provenance.json`; the root
Absinthe ebin contains 468 BEAMs with artifact-set SHA-256
`c404f6b56c6a75dfeee5f201d0bebe661c7bfd2619260a7bf8601fe7e30afb9a`.
The experiment script is committed at `4b87020`. Host: macOS, Apple M2 Pro,
OTP 28.5.0.1; results are process measurements, not a Linux cgroup test.
Other campaign builds were paused for the two measured passes; the host is
not an otherwise dedicated benchmark machine. Wall time is indicative.

| Mode | Wall time | Peak RSS (bytes) | Process memory after GC (bytes) |
| --- | ---: | ---: | ---: |
| Retain analysis and evidence | 102.23 s | 2,907,734,016 | 2,733,561,344 |
| Keep only inventory | 59.17 s | 481,656,832 | 372,536 |

The sorted structural inventory SHA-256 is identical in both modes:
`2d56f3c2c6fe6f6a0ff324497fec4346013e19a92ff17ec380ff7ee93038e0a5`.
Peak RSS fell by about 83%. This supports processing modules before retaining
compact results. It does not establish equality of findings, fingerprints,
coverage regression decisions or completion/exit status: those stages did
not run. It also does not show the public task fits a 6 GiB Linux limit.

The first sandboxed retain attempt completed analysis, but macOS denied
`time -l` access to `kern.clockrate`, so its resource command returned 1 and
provided no RSS. It is excluded from this table; the successful measured
retain pass repeated the same workload with that access permitted.

## Next implementation experiment

Keep the existing full-analysis API for Explain and callers that inspect
`Run.modules`. Add a compact execution path for normal public-task reports
only after separating module-local analysis/rules from project-wide policy:

1. Per module: analyse, classify, recheck reachability in complete module
   context, produce findings and compact inventory/ledger contributions. Keep
   exports and overridable-default metadata needed to distinguish removed
   specs from deleted definitions.
2. Across modules: reconcile the baseline once, detect removed specs and
   regressions, apply whole-project floors and completion rules, then sort
   and render. Preserve excluded, unavailable and failed modules explicitly.
3. Release translated graphs after their last use. Findings can themselves
   retain descr terms, so inventory-only memory is a lower-bound experiment,
   not an estimate of final product RSS.

Adopt only after full/compact equivalence on fixtures (including missing
specs, exclusions, partial filters, unsupported chunks, reachability failure,
adapter changes, baselines and disabled SL008), both compiler suites, and
unchanged corpus findings/ledger/fingerprints apart from explicitly approved
presentation fields. Repeat the same Linux Absinthe workload under the
unchanged 6 GiB hard cap, and keep the existing frozen corpus budgets.

Reproduce with a separately compiled SpecLint on the exact compiler and
externally qualified corpus inputs:

```sh
elixir -pa "$SPEC_LINT_EBIN" bench/memory/retention.exs retain "$CORPUS_BUILD_LIB" absinthe
elixir -pa "$SPEC_LINT_EBIN" bench/memory/retention.exs discard "$CORPUS_BUILD_LIB" absinthe
```

`results-m8/` retains both JSON outputs and successful macOS time measurements.
