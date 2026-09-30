# Local M8 qualification

Frozen runtime commit: `4b87020`. Each lane used an isolated clean copy,
separate build directories and OTP 28.5.0.1. Alternate gating, diagnostic
and unsupported compiler paths were supplied to the integration tests.

| Compiler | Passed | Skipped | Excluded | Suite seconds |
| --- | ---: | ---: | ---: | ---: |
| c24c235 | 518 | 1 | 9 | 357.8 |
| 1.20.4 | 520 | 1 | 7 | 405.0 |

Both lanes passed formatting, full strict Credo and Dialyzer. Both production
self-checks exited 0 with 425 functions/slices compared and zero findings.
Per-lane summaries, logs and reports are retained here; machine-specific
paths are sanitized. The separate [Linux campaign](../github-quality.md)
records its own test selections and skips.
