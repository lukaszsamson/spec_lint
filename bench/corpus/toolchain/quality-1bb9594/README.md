# Final macOS quality qualification — 1bb9594

Implementation commit `1bb95947c709a467bc89a65ed61d5829c220086f`.
This directory records the final full quality checks, separately from the
historical campaigns and the earlier failed setup attempts.

The fork lane ran in the source checkout; the release lane ran in an
independent clean clone with separate build directories. This avoids
ExUnit's checkout-relative `tmp_dir` collisions. Both used the qualified
compiler inputs, OTP 28.5.0.1, the other qualified gating compiler for
cross-compiler tests, and installed 1.19.4 for unsupported-version tests.
The fork also named actual upstream 648b2a9 for the same-version dependency
regression. Test, development Dialyzer and production self-check build paths
were kept separate. Custom `file_system` development compilation is refused;
the self-check intentionally covers the distributed runtime in `MIX_ENV=prod`.

| Check | Fork c24c235 | Release 1.20.4 |
| --- | --- | --- |
| Full tests | 497 passed, 1 skipped, 9 excluded | 499 passed, 1 skipped, 7 excluded |
| Full strict Credo | Pass | Pass |
| Format | Pass | Pass |
| Dialyzer (runtime modules, dev build) | 0 errors | 0 errors |
| Production self-check | 419 specs, 0 findings, complete, exit 0 | 419 specs, 0 findings, complete, exit 0 |

Adapter-specific exclusions are intentional. The skipped diagnostic-only
public-task test runs on actual 648b2a9 in the separate Linux diagnostic lane,
where all eight selected diagnostics passed. Linux full and targeted scope
is documented in `../linux-results.md`; it is not a full final Linux corpus
campaign.

Earlier attempts are not counted as passes: reused build directories held
obsolete v2 records and were correctly refused; a simultaneous run from one
checkout collided in ExUnit's shared fixture directories; Dialyzer found
three type/void-return issues which were corrected before the final freeze.
The subsequent final suites passed on the frozen source. A development
self-check also correctly refused the custom `file_system` compiler; this
restriction is documented rather than hidden by an exception.

The release lane additionally records compiler identity, the clean source
identity and SHA-256, production compilation with warnings as errors, and
macOS `time -l` measurements for each command. Its frozen source SHA-256 is
`3e1484003bde47d1278aa929a687ea4683f32a267d6f1b8f2657b84c7451d978`.

Host-specific temporary paths in copied logs and self-check reports are
normalized to `$QUALIFICATION_PATH/<basename>` for publication. Original
local logs were retained; this changes no results, counts or compiler identities.
