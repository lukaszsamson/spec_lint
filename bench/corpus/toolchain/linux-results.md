# Local Linux qualification evidence (2026-09-29)

The full-suite qualification and stress results precede the later
dependency-compiler provenance fix. They qualify the frozen implementation
identified below, not that subsequent fix. Post-fix focused validation is
recorded separately at the end of this report.

This local experiment uses Debian 13 (trixie), Linux ARM64, Erlang/OTP
28.5.0.4 (ERTS 16.4.0.4), and four BEAM schedulers. It is not a run of the
manual Ubuntu 24.04 / OTP 28.5.0.1 GitHub Actions workflow. The Docker image
is `erlang@sha256:ce4ad5474798b44ca43c7146be2547ec76a537c52713d8af9b745c802c6dfc51`
(local image ID `sha256:8b44049edc0ea74f5bf1355cee4154975580fe7c7603d9bc1e3b3a5416705f30`).
The container memory and memory-plus-swap limits are both 6,442,450,944 bytes
(6 GiB); no macOS BEAM files, dependency builds, or PLTs are copied into Linux.

The preliminary repository snapshot was taken at `2026-09-29T21:09:58Z`,
from HEAD `a50b0d7e81d496f361e0c2c78c9d8f3109286aab` plus the working tree.
Its compressed archive SHA-256 is
`4dd7915cb71655c8330c6f5923b9ab39588caf4356a3f8de413c0529aad0f80f`.
It predates the final integrated production fixes; preliminary preflight
results alone do not qualify those later changes.

`install_ci_elixir.sh` installed the exact audited
`v1.20.4-otp-29.zip` archive and built both full pinned source revisions on
OTP 28.5.0.4. All three strict preflights succeeded without changing compiler
digest pins:

| Compiler | Strict build digest | Preliminary preflight peak RSS |
| --- | --- | ---: |
| 1.20.4 / `759443e` | `ab40621dc4c1ee7ce26ad192bb3ab0dd65c434816cd2dfb247faff3446e85766` | 367,004 KiB |
| Fork `c24c23538d521d25edd6a9a7a66fc5206caab70e` | `ae7d8dc230f53eebfc55d8370437127221b8f4caeba74f6e3ebcf4fc05c1e947` | 347,940 KiB |
| Upstream `648b2a94934664cfd2c788348d02d799c68faa69` | `cce56065b5670aa6e086839b1465dd22bbee4f964bae2673843a50e4a6856cce` | 356,084 KiB |

Upstream preflight returned the expected diagnostic-only refusal reason:
mixed list/bitstring `for ... into` inference can gate correct specs.
It therefore remains report-only. Both gating compilers match the committed
qualification pins in this Linux environment.

Raw local evidence is retained in `/tmp/spec-lint-linux-evidence`: compiler
identity JSON, installation logs, preliminary preflight logs and GNU time
measurements, and the snapshot archive. That temporary location is a local
inspection aid, not a portable corpus input or a permanent CI artifact.
The portable subset in [`linux-evidence`](linux-evidence) contains compiler
identities, quality resource measurements, and Absinthe timing/status/OOM
counters. The resource command line is replaced by a description to avoid
publishing machine-specific path lists; measurement fields are preserved.

The integrated source snapshot was refreshed at `2026-09-29T21:25:14Z`.
Its metadata-free compressed archive SHA-256 is
`4fd766e70e88b41e6de41820941f36586238cd61ebfe117ddcdba1ae576eb853`.
It includes the complete-default-compiler-pipeline guard, updated failure
fixtures, and the corpus temporary-directory cleanup regression. Later
upstream documentation edits do not change production code or tests.
Git metadata was copied separately so corpus provenance tests can inspect
the actual checkout HEAD. The copied checkout was added as a Git safe
directory within the container because macOS and Linux owner IDs differ.
Archive creation uses `tar --no-xattrs --no-mac-metadata` to exclude macOS
metadata sidecars. Hex and Rebar were bootstrapped inside Linux; dependencies
were resolved from the committed lock and their builds remained inside Linux.
The final lanes use separate compiler build paths and PLT directories.

Two unsuccessful setup attempts are retained rather than counted as passes:

* The first integrated release suite passed 478 of 488 selected tests in
  172.7 seconds, with 3 skipped and 6 excluded. Five failures came from
  omitted checkout Git metadata; five came from the old resource-test
  fixture's now-forbidden custom compiler. The fixture was updated while
  preserving its crash regression coverage.
* The first final refresh stopped at format checking because macOS archive
  metadata introduced `._*.exs` sidecars. These files were removed and the
  source snapshot was recreated without macOS metadata.

At `2026-09-29T21:27:51Z`, the semantics-preserving `Enum.each` correction
to `lib/mix/tasks/spec_lint.ex` was copied before cross-compiler tests and
Dialyzer. Its SHA-256 is
`067a56630e99591b375b3d76db5bb2d14081d23a0cb83eb11536a60b10ad834b`.
A comparison of all production and test file hashes after the runs found
only subsequent SPDX comment headers in three compiler adapter files;
all test files matched the final workspace.
An independent comparison against `git archive 56db9cf lib test` found zero
source-byte differences: the tested production and test implementation is
commit `56db9cf`. Commit `90cecbf` subsequently adds SPDX headers and package
metadata without changing this implementation. The local copied Git HEAD
remains the older snapshot HEAD above; this distinction is why source bytes
were compared directly rather than presenting that checkout HEAD as the
tested implementation revision.

The runs exposed a CI harness bug: the original script's globally exported
`MIX_ENV=test` made Dialyzer analyze deliberately invalid fixture specs.
Both original gating invocations therefore ended with Dialyzer exit 2.
`ci_quality.sh` now invokes Dialyzer with `MIX_ENV=dev` and a separate build
path. Both production-only Dialyzer reruns passed with zero errors. Other
quality steps did not need to be repeated for this environment-only fix.
The results below combine the passing gating steps and corrected Dialyzer
reruns; they are not a claim that the original failing script invocations
returned success. The corrected script SHA-256 is
`d789cc638a616e0e4b9f3f17f30eddcab0725132cf17b19953a79d7393bebada`.

| Required check | 1.20.4 release | `c24c235` fork | `648b2a9` upstream |
| --- | --- | --- | --- |
| Frozen dependencies, warnings-as-errors compile, format, strict Credo | Pass | Pass | Pass |
| Strict pinned preflight | Pass | Pass | Pass |
| Gating policy | Allowed | Allowed | Refused as expected |
| Alternate gating compiler preflight | Pass | Pass | Not applicable |
| Full suite | 491 passed, 2 skipped, 6 excluded | 488 passed, 2 skipped, 9 excluded | Not a gating lane |
| Explicit cross-compiler suite | 5 passed, 494 excluded | 5 passed, 494 excluded | Not applicable |
| Production Dialyzer | 0 errors | 0 errors | Not a gating lane |
| Selected upstream diagnostics | Not applicable | Not applicable | 8 passed |

GNU time wall measurements and peak RSS for the main checks:

| Check | Release wall / peak RSS | Fork wall / peak RSS |
| --- | --- | --- |
| Full suite | 216.72 s / 278,780 KiB | 361.73 s / 276,620 KiB |
| Explicit cross-compiler suite | 45.94 s / 268,736 KiB | 48.86 s / 261,520 KiB |
| Corrected production Dialyzer | 93.21 s / 1,305,672 KiB | 59.85 s / 1,214,200 KiB |

The upstream diagnostics used 4.50 seconds and 160,468 KiB peak RSS.
Every measured quality command stayed below 1,200 seconds and 6,291,456 KiB;
the container reported no OOM. Some commands reused prior Linux-only
dependency builds or PLTs after failed setup attempts; these measurements
are qualification resource observations, not clean-cache performance claims.
The workflow now fetches full Git history so historical upgrade consumer
tests can run. The local copy also had full history.

No full corpus replay has been run by this experiment. The representative
Absinthe stress experiment below does not replace the fifteen-corpus replay
and detection-cohort checks.

The representative Absinthe input is revision
`1372ceb5f8226175050a38821601cd57738c177b`, copied together with its frozen
dependency source directories. The source archive SHA-256 is
`0e08720a0c8390567da75c50a4f78790510839bfeaa3a19643a84beb95d665b3`.
Every `_build`, BEAM file, and PLT was excluded from the copy. No dependency
resolver was run. The frozen `mix.lock` SHA-256 is unchanged:
`fe6c4dc1e42fa77b5f8dd58caed92ecef2dac5a436ffac6610284d615195cdd6`.
The project has no `config/prod.exs`, so an initial prod preparation attempt
failed before compilation. Using `MIX_ENV=test`, matching the frozen campaign
inputs, succeeded in 5.24 seconds with 293,832 KiB peak RSS and produced
468 Absinthe BEAM files, the same count as the reference provenance.

The timed Elixir 1.20.4 product run began at `2026-09-29T21:53:24Z` after
the coordinated macOS replays finished, using the frozen implementation
matching `90cecbf` apart from SPDX comment headers. The runner file SHA-256
matches that commit exactly:
`f40280cc4b98ae887b3092fbecd61e7ac138b96895543607b448043ef606309f`.
It used the same target and nine code-path directories as the frozen corpus
runner, `MIX_ENV=test`, `--ci --format json`, four schedulers, a 1,200-second
timeout, and the container's enforced 6 GiB memory/no-swap limit.

**The 6 GiB Absinthe run failed to complete.** The kernel killed the product
VM with signal 9 after 83.37 seconds. The captured shell status was 137;
GNU time measured 6,268,400 KiB peak RSS. The cgroup memory peak reached
exactly 6,442,450,944 bytes, and both `oom` and `oom_kill` counters increased
from 0 to 1. No JSON report was written, so the expected complete report,
exit 1, seven gates, and fingerprint equality cannot be certified for this
Linux run. It was not a timeout or a compiler digest failure. The memory
limit was not increased and the run was not retried.

GNU time's resource file reports `Command terminated by signal 9` but also
prints `Exit status: 0`; that last field must not be read as success.
The separately captured shell status and cgroup OOM counters establish the
actual failure. Raw evidence is retained as `absinthe-linux.*` under the
temporary evidence directory above.

The quality suite results remain valid; this stress failure means the
heaviest representative corpus has **not** been qualified at 6 GiB on this
Linux environment. The committed macOS-derived Absinthe RSS budget is
8,256 MiB, which is larger than this experiment's enforced 6 GiB cap.

Bounded diagnostics in a separate frozen-source copy sampled analysis with
arity-only tracing; no full result terms were copied to the tracer. A probe
stopped after 318 module starts at 19.10 seconds of analysis (25.10 seconds
including compilation), before evidence classification, rule execution, or
rendering. Its largest sampled stack was `Translate.build_map` calling
`Module.Types.Descr.map_descr`; heap increases appeared across several
`Absinthe.Phase.Document.Arguments` modules. A second prefix forced full GC
at module boundaries and still reached approximately 2.23 GB VM allocation
by module 310 after 25.68 seconds, with approximately 635 MB process heap
remaining after a full GC at that module boundary. The first probe peaked
at 3,356,088 KiB RSS; the GC probe at 2,607,340 KiB. Their sampled 2 GiB
stop threshold could be overshot between samples; neither raised the
container's 6 GiB limit or ran the complete product workload.

This points to retained translated analysis and large temporary type
construction, not eager report printing. Printing is already lazy for
findings, and `Report.view/1` already omits per-module analysis before
rendering. Full GC alone did not remove the growth. A practical hypothesis
is to stream each module through classification, reachability, rules, and
coverage, retaining compact findings/inventory/ledger summaries for normal
lint output. Explain and API callers that require full analysis would keep
the existing retention mode. This is a proposal, not an adopted or validated
memory fix: it must preserve complete reports, baseline/lost-spec behavior,
gates and structural fingerprints, and then complete the same bounded
Absinthe workload before any success claim.
A separate four-module deep-size diagnostic reached its 120-second timeout
before recording its first result; it is inconclusive and is not used to
support the hypothesis. No further memory experiments or production changes
were made during this investigation.

## Focused Linux follow-up after the dependency-provenance fix

At `2026-09-29T22:10:49Z`, the stable updated `lib`, `test`, quality script,
Mix project and lock/config inputs were copied into Linux without any build
output or macOS metadata. The source archive SHA-256 is
`e362d950195b35b866a450291cb11eef7ea6976bf7ca97523def10930c0eeee7`.
The host checkout was `90cecbfd6992e0ed9aaaac0766325b69ba6fce1c` plus the
uncommitted dependency-provenance fix. A final source comparison identified
two subsequent Dialyzer-only changes: open-map/result type specifications in
`BuildRecord` and `Enum.each` for a void dependency-check helper. Those final
changes are validated separately below. No test files changed. Each compiler
used a separate fresh Linux build directory.

Both gating compilers passed warnings-as-errors compilation, format checking
and strict Credo, followed by these three focused test files:
`test/spec_lint/build_record_test.exs`,
`test/integration/build_record_test.exs`, and
`test/integration/dependency_provenance_test.exs`.

| Post-fix check | Result | GNU time wall | Peak RSS |
| --- | --- | ---: | ---: |
| Fork focused suite, qualified release alternate and actual `648b2a9` diagnostic dependency | 26 passed; none skipped/excluded | 88.17 s | 170,908 KiB |
| Fork explicit `--only diagnostic_dependency` | 1 passed, 4 excluded; none skipped | 5.98 s | 133,704 KiB |
| Release focused suite, qualified fork alternate | 25 passed, 1 excluded; none skipped | 71.68 s | 172,996 KiB |
| Actual upstream selected diagnostic regressions | 8 passed; none skipped/excluded | 6.18 s | 162,224 KiB |

The release exclusion is the V121-only actual upstream-dependency test;
that test was explicitly run under the fork. The upstream checks select
`compiler_gating_test.exs`, `upstream_qualification_test.exs` and
`integration/report_only_compiler_test.exs`, confirming diagnostic refusal
after the changed dependency compile path. Upstream warnings-as-errors
compilation also passed. Every captured command status was 0, and every
command stayed within the existing 1,200-second / 6 GiB quality limits.
Portable measurements are in
[`linux-evidence/dependency-fix-resources.json`](linux-evidence/dependency-fix-resources.json).

At `2026-09-29T22:21:08Z`, the final two-file Dialyzer delta was copied:
`BuildRecord`'s open-map/result type specifications and the void dependency
helper's `Enum.each`. The delta archive SHA-256 is
`0efc64b5cb714323ff438319e8018c390c5baeaffe7fe655a0369c1e3b2d6d79`.
Warnings-as-errors compilation passed on all three compilers; format and
strict Credo passed again on both gating compilers. The fork's explicit
diagnostic-dependency regression passed 1 test with 4 excluded, the release's
dependency-provenance file passed 4 with 1 excluded, and the upstream
selected diagnostics passed all 8. None were skipped. Their GNU time walls
were 4.93, 12.41 and 5.89 seconds respectively. Every command returned 0.
A final byte comparison of all production and test files against the base
archive plus this delta found no differences in the current workspace.
Measurements are in
[`linux-evidence/dependency-final-resources.json`](linux-evidence/dependency-final-resources.json).

The full Linux suites, Dialyzer and full corpus campaigns were **not repeated**
after this dependency fix. The earlier full-suite evidence remains explicitly
pre-fix; this section certifies only the listed focused post-fix checks.
