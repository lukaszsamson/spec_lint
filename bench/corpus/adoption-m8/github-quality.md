# Linux qualification (M8)

GitHub Actions [run 36772056301](https://github.com/lukaszsamson/spec_lint/actions/runs/36772056301)
completed successfully on commit `4b87020d783ba05465bbbe84b2a19de04f5e8247`.
The workflow ran on Linux with Erlang/OTP 28.5.0.1 and qualified compiler
inputs. Both gating compiler jobs passed formatting, Credo, ExUnit, Dialyzer
and the expected compiler gating policy. Production self-checks are part of
the separate local qualification, not this workflow. A report-only job using upstream
revision `648b2a9` also passed.

Each compiler lane's ExUnit result totals 528 when passed, skipped and
excluded tests are combined. The counts below keep selected tests, skipped
tests and excluded tests distinct:

| Gating lane | Selected | Passed | Skipped | Failed | Excluded |
| --- | ---: | ---: | ---: | ---: | ---: |
| Elixir 1.21.0-dev (`c24c235`) | 519 | 517 | 2 | 0 | 9 |
| Elixir 1.20.4 | 521 | 519 | 2 | 0 | 7 |

The cross-compiler integration selection passed 6 tests in each lane; the
other 522 were excluded from that selection. The `diagnostic_dependency`
selection ran in the `c24c235` lane only: 1 passed, 527 excluded. The
report-only `648b2a9` lane ran its selected 8 tests, all passed.

Credo reported no issues in either gating lane (2,522 modules/functions on
`c24c235`; 2,520 on 1.20.4). `mix format --check-formatted` and Dialyzer also
passed in both lanes; Dialyzer reported zero errors. The report-only lane's
Credo check found no issues in 2,522 modules/functions.

This records the workflow result for the frozen M8 source snapshot. The
public-project campaign results and its local macOS resource measurements
are documented in [README.md](README.md); they are separate from this Linux
qualification run.
