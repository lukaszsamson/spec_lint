# Public Mix task adoption campaign (M8)

Seven pinned public projects from the OSS inventory, all using `MIX_ENV=test`.
Original checkouts and the Bandit, Kino and Timex holdouts are untouched.
`inputs.json` records complete source revisions and SHA256 digests of the
original locks. Copies are git archives of HEAD; original tracked sources are
clean. Existing dependency sources were copied where available, missing ones
fetched with `mix deps.get`, and every source lock remained byte-identical.
The only project-source modification in each isolated copy is one local
`{:spec_lint, path: ..., runtime: false}` entry in its dependency list.

The compiler is the exact qualified Elixir 1.20.4 installation, revision
759443e, with Erlang 28.5.0.1. No requirement, alias or compiler-list edits are
made to get a success. Phoenix's function compile alias and Livebook's suffix
compiler are expected refusals. NervesHubWeb's `~> 1.18.0` requirement is an
expected compatibility blocker on this compiler, not a successful analysis.

The first public-task run follows a successful plain `mix compile` for the
four supported projects. It measures adoption from a pre-existing build:
SpecLint must establish its own provenance and force the needed compilation.
`cold` in filenames means no prior SpecLint evidence, not an empty build tree.
Plain build elapsed times were Absinthe 6.77 s, Gettext 3.73 s, Tableau 33.18 s,
and Credo 4.74 s. Refusal cases are invoked without a preceding project build.

The driver runs the public task, repeats it, generates a baseline, then runs
CI against that baseline. Exit 1 accompanied by a complete JSON report means
reported gates; process exit alone does not establish analysis completion.
Exit 2 means incomplete or refused. Each command is
measured with macOS `/usr/bin/time -l`. Process RSS describes these local runs,
not the separate Linux cap acceptance workload.

`run.py` expects prepared `projects/` and `evidence/` directories under
`ADOPTION_ROOT`; set the qualified compiler and Erlang bins on PATH and set
`SPEC_LINT_ROOT` for a different tool checkout. A runtime SHA256 file map pins
the exact runtime source used, alongside Git HEAD `4b87020`; these runtime
files match the frozen commit. Generated report
findings are triaged as defect families rather than counted as recall gains.

During Absinthe's incremental run, ordinary host file reads became slow.
The incremental task took 369.56 seconds versus 123.81 seconds for the first
run, while user CPU was 71.86 versus 72.24 seconds. Host free memory was about
58 MiB on a 32 GiB machine during the slow run. These wall times are observed
measurements under host pressure, not a controlled performance comparison.

After the incremental run completed, a best-effort process monitor imposed
600 seconds per command and 8 GiB RSS as host-safety ceilings. These limits
were introduced during the campaign; they were not preregistered acceptance
budgets. They differ from the frozen raw-analysis budget and do not qualify
that budget. Recorded time/RSS is also checked after completion to catch
exceedances missed between samples. The watcher observes descendants of each
campaign time command and terminates only an over-limit campaign BEAM.

Mix rejects NervesHubWeb's Elixir requirement with exit 1 before SpecLint
writes any report. That is an environment blocker, not a gated finding. The
initial driver retried incremental/baseline/CI, all returning the same
immediate requirement error; those attempts are retained, with no acceptance
claim. The corrected driver now requires a report before subsequent runs.

The published driver was hardened after measurements: it removes stale
reports, verifies complete JSON and matching process/report exits, stops on
failed runs, verifies baseline creation, and integrates safety sampling.
Acceptance also requires a numeric RSS measurement and no intervention; a
missing measurement cannot be mistaken for a successful complete report.
The actual measured reports were checked independently against their process
outcomes. `measured-safety-monitor.py` archives the monitor used during the
campaign; it contains that measurement's scratch paths.

`dependency-source-digests.json` records each copied/fetched dependency's
postbuild tree digest and root mix.exs before/after injection digests. Dependency
tree hashes exclude `.git` and `_build` but include generated files elsewhere;
they pin observed sources after builds rather than claiming an original Hex
tarball identity. The unchanged lock alone does not certify copied dependency
sources. No dependency source files are published here.

## Results

| Project | Status | Functions / slices compared | Findings / gates | First / second task, seconds | Baseline CI |
| --- | --- | --- | --- | --- | --- |
| Phoenix | compile alias refused | unavailable | unavailable | 22.67 / not run | not run |
| Livebook | suffix stage refused | unavailable | unavailable | 45.78 / not run | not run |
| NervesHubWeb | Elixir requirement blocker | unavailable | unavailable | 0.88 / failed retry 0.72 | blocked |
| Absinthe | complete | 447 / 449 | 9 / 7 | 123.81 / 369.56 | exit 0 |
| Gettext | complete | 34 / 34 | 0 / 0 | 2.94 / 0.82 | exit 0 |
| Tableau | complete | 2 / 2 | 1 / 0 | 28.69 / 2.70 | exit 0 |
| Credo | complete | 11 / 11 | 0 / 0 | 4.07 / 1.10 | exit 0 |

All four completed projects repeated with identical finding and ledger data,
no Elixir compilation progress lines, and unchanged locks. Baselining is an
acknowledgement: Absinthe's underlying seven gates remain in the report as
baselined findings; exit 0 does not mean they disappeared. The low Tableau
and Credo counts are the declared-spec surface eligible for analysis, not
whole-codebase correctness coverage.

All measured commands stayed below the introduced safety ceilings in their
completed time/RSS records; no watcher intervention occurred. Highest RSS was
Absinthe baseline CI at 4,403,085,312 bytes (4.10 GiB). These public-task runs
neither establish the frozen raw-analysis budget nor demonstrate Linux cap
acceptance. See [triage](triage.md) for the confirmed library defect families.
