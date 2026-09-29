# Published GitHub Linux qualification

The first published [Clean Linux compiler qualification run](https://github.com/lukaszsamson/spec_lint/actions/runs/36642729295) completed **successfully in all three lanes** on 2026-09-29. It tested commit `ce2e81471573378ef8d4fd93db33b1b9f97df6ba`; its production and test implementation is the final `1bb95947c709a467bc89a65ed61d5829c220086f` generator-order/dependency-provenance implementation. No compiler pins were changed, failures suppressed, or workflow fixes needed during this run.

## Environment and boundaries

- Fresh GitHub-hosted Ubuntu 24.04.5 LTS AMD64 runners, with OTP **28.5.0.1** installed by `erlef/setup-beam@v1`.
- Runner image `ubuntu-24.04`: version `20260920.314.1` for both gating lanes; `20260927.320.1` for the diagnostic lane.
- Full-history checkout (`fetch-depth: 0`), exact compiler archives/revisions installed in empty directories, fresh dependency fetch and Linux builds. No macOS BEAMs or prepared local build directories were used.
- `ERL_FLAGS='+S 4:4'`; each measured quality command has a **1200 s timeout**, a 15 s kill grace period, and a **6291456 KiB (6 GiB) measured peak-RSS acceptance threshold**. Each job has a 60-minute timeout. The RSS threshold is checked after execution; this workflow does not impose the Docker experiment's hard 6 GiB cgroup limit.
- GNU `/usr/bin/time -v` reports below include the command and subprocess work. Job durations also include setup, compiler installation and artifact upload. Lanes ran concurrently, so these are qualification measurements rather than isolated benchmark comparisons.

## Exact results

Every lane passed dependency fetch, warning-free compilation, format checking, strict Credo, strict compiler preflight and its expected gating policy. Both gating lanes also passed alternate-compiler preflight and production-only Dialyzer in a separate `MIX_ENV=dev` build with newly constructed PLTs.

| Check | Elixir 1.20.4 / `759443e` | Fork `c24c235` | Upstream `648b2a9` |
| --- | --- | --- | --- |
| Lane outcome | Gating: success | Gating: success | Report-only: success |
| Full default test suite | 498 passed, 2 skipped, 7 excluded | 496 passed, 2 skipped, 9 excluded | Not requested |
| Explicit cross-compiler suite | 5 passed, 502 excluded | 5 passed, 502 excluded | Not requested |
| Explicit actual-648 dependency regression | Excluded by configuration | 1 passed, 506 excluded | Not requested |
| Selected upstream/public-task diagnostics | Covered where applicable by default suite | Covered where applicable by default suite | 8 passed, no skips or exclusions |
| Dialyzer | 0 errors, 0 skips, 0 unnecessary skips | 0 errors, 0 skips, 0 unnecessary skips | Not requested |
| Gating reasons | `[]` | `[]` | Expected diagnostic-only refusal |

The two default-suite skips in each gating lane are intentional: the public-task report-only test requires actual `648b2a9`, and the unsupported-1.19 consumer test requires `SPEC_LINT_UNSUPPORTED_ELIXIR`, which this matrix does not install. The actual report-only public-task test ran in the upstream lane. The historical `128e2af` upgrade checkpoint was available through full history. Adapter-specific tests explain the remaining default exclusions; the release lane additionally excludes the actual-648 dependency tag. Explicit `--only` runs above have their own exclusion counts and must not be added to the default-suite totals as distinct tests.

## Resource evidence

All recorded command exit statuses were zero, and every measured peak was below the configured threshold.

| Command | 1.20.4 wall / peak RSS (KiB) | c24c235 wall / peak RSS (KiB) | 648b2a9 wall / peak RSS (KiB) |
| --- | --- | --- | --- |
| Full tests | 362.42 s / 295060 | 476.02 s / 280340 | — |
| Explicit cross-compiler tests | 81.27 s / 271948 | 107.96 s / 263244 | — |
| Actual-648 dependency regression | — | 10.65 s / 256352 | — |
| Dialyzer including fresh PLTs | 103.27 s / 1251160 | 141.88 s / 1191104 | — |
| Selected upstream diagnostics | — | — | 6.50 s / 141800 |
| Complete job | 10 min 41 s | 15 min 9 s | 1 min 32 s |

Job interval: `2026-09-29T22:59:32Z` through `2026-09-29T23:14:41Z`. The largest recorded quality-command peak across the matrix was the release Dialyzer run, **1251160 KiB**.

## Compiler identities and retained artifacts

The strict preflight build digests match the existing pins:

| Compiler | Checker | Strict build digest |
| --- | --- | --- |
| 1.20.4 / `759443e` | `elixir_checker_v8` | `ab40621dc4c1ee7ce26ad192bb3ab0dd65c434816cd2dfb247faff3446e85766` |
| c24c235 | `elixir_checker_v10` | `ae7d8dc230f53eebfc55d8370437127221b8f4caeba74f6e3ebcf4fc05c1e947` |
| 648b2a9 | `elixir_checker_v10` | `cce56065b5670aa6e086839b1465dd22bbee4f964bae2673843a50e4a6856cce` |

Uploaded artifacts retain the exact compiler identity JSON, each executed quality command's log, and GNU time resource measurements:

- [linux-1.20.4-gating](https://github.com/lukaszsamson/spec_lint/actions/runs/36642729295/artifacts/11067194130), [job log](https://github.com/lukaszsamson/spec_lint/actions/runs/36642729295/job/109658530198).
- [linux-c24c235-gating](https://github.com/lukaszsamson/spec_lint/actions/runs/36642729295/artifacts/11067612539), [job log](https://github.com/lukaszsamson/spec_lint/actions/runs/36642729295/job/109658530221).
- [linux-648b2a9-report-only](https://github.com/lukaszsamson/spec_lint/actions/runs/36642729295/artifacts/11067486029), [job log](https://github.com/lukaszsamson/spec_lint/actions/runs/36642729295/job/109658530050).

This run supplies final-implementation full Linux correctness/quality evidence. It does **not** repeat the 15-project corpus, establish Linux corpus timing budgets, test an unsupported 1.19 compiler, or supersede the separate [6 GiB Absinthe OOM experiment](linux-results.md). Upstream 648b2a9 remains diagnostic-only despite its successful diagnostic lane.
