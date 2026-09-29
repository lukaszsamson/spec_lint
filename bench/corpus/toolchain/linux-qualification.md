# Clean Linux qualification

`.github/workflows/linux-qualification.yml` is a manual clean-machine
qualification workflow on Ubuntu 24.04. It runs without dependency or build
caches and retains compiler identities, command logs, and GNU time resource
measurements even when a job fails. It has three independent matrix entries:

* The audited precompiled Elixir 1.20.4 OTP-29 archive, running on OTP 28.5.0.1.
* The fork revision `c24c23538d521d25edd6a9a7a66fc5206caab70e`, built from source
  on OTP 28.5.0.1.
* Upstream `648b2a94934664cfd2c788348d02d799c68faa69`, built from source on
  OTP 28.5.0.1, for report-only diagnostics.

The first two entries install the other gating compiler too and set
`SPEC_LINT_OTHER_ELIXIR` explicitly. They run compile with warnings as errors,
format, strict Credo, strict preflight, full tests, the explicitly selected
cross-compiler tests, and Dialyzer. The upstream entry checks that gating
qualification is refused and runs only the compiler gating and upstream
qualification regression tests, alongside compile, format, Credo and preflight.
A successful diagnostic entry does not certify upstream CI gating.

Each command has a 1,200-second hard timeout with a 15-second kill grace period
and an independently checked 6 GiB peak RSS budget. RSS is checked after command
completion; it is not an OS allocation limit. The entire job has a 60-minute
limit. The logs identify timeout, failure and excessive RSS explicitly. These
quality-check budgets are separate from the per-corpus budgets in
`bench/corpus/budgets.json`.

Run the same checks in a fresh Linux checkout after installing OTP and the
Linux tools (`git`, `make`, `curl`, `unzip`, `jq`, GNU `time`, GNU `timeout`):

```sh
bench/corpus/toolchain/install_ci_elixir.sh c24c235 /tmp/compiler > compiler.identity.json
bench/corpus/toolchain/install_ci_elixir.sh 1.20.4 /tmp/alternate > alternate.identity.json
export PATH=/tmp/compiler/bin:$PATH
export SPEC_LINT_OTHER_ELIXIR=/tmp/alternate/bin
bench/corpus/toolchain/ci_quality.sh gating qualification
```

Both installation destinations must be fresh. Use `648b2a9` and `report-only`
for the diagnostic entry. The scripts never rewrite qualified compiler
module digests or accept a revision alone as qualification. A different Linux
compiler digest fails preflight and requires review of the build identity,
capability probes and compiler audit before any new digest is committed.
Workflow creation itself is not evidence that Linux qualification passed.

This workflow does not claim to replay the full corpus. That requires fifteen
pinned source checkouts, their frozen dependency locks, the appropriate
per-compiler build roots, the expansion manifest, and compiler-specific stdlib
source provenance. Some library/dependency combinations require separate
compile procedures (including Ash and Nx); installing dependencies from their
current registry resolution would not recreate the committed campaign inputs.
Prepare and inspect those inputs before running `compile_corpora.sh` and
`run.sh`. Check resource budgets, exact replay equality (only build-dependent
`beams` differences are allowed), and detection cohort validation separately.
Upstream diagnostic runs must not be presented as CI-qualified corpus runs.
