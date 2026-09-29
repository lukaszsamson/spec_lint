# Generator order and public Oban probe — 2026-09-30

The public Mix task was exercised on a temporary source copy of Oban
`23fa8176b3586ca84f5859793739fad798e69d2b`, with 43 copied locked dependency
source directories and no copied build artifacts. The sole project change
was adding the local SpecLint dependency. The original frozen checkout
remained clean. No dependency resolution ran (`HEX_OFFLINE=1`).

The command used the qualified Elixir 1.20.4 archive and `MIX_ENV=test`:

```sh
MIX_ENV=test HEX_OFFLINE=1 mix spec_lint --ci --format json --output report.json
```

The frozen, initial copied and final copied lockfiles all have SHA-256
`f243a66a968755e9d4b2192dbc402d0a8f27920293a9c7ffc42e59f822af6f18`.

## Unnecessary rejection corrected

The first run stopped with exit 2 before analysis because `earmark_parser`
uses `[:leex, :yecc, :erlang, :elixir, :app]`. The original guard accepted
only `[:yecc, :leex, :erlang, :elixir, :app]`.

Two independent source reviews and the implementation review established
that accepting both orders preserves production evidence. The qualified
c24c235, 648b2a9 and 1.20.4 generator source files are byte-identical:

| Source | SHA-256 |
| --- | --- |
| `lib/mix/lib/mix/tasks/compile.leex.ex` | `b33cdcb8077d1d31847ffc2673551e1fa5d6d0849bebd8db475260a85cb16d86` |
| `lib/mix/lib/mix/tasks/compile.yecc.ex` | `5ba565d55f25e006ce1661b0b400f542ea7ca6aaffbb0d49a27edcb5b4301207` |

They generate `.erl` sources from `.xrl` and `.yrl`, forcing their output
paths through the scanner/parser options. The shared Erlang compilation
helper emits module-production events only for `dest_ext == :beam`.
Both accepted orders run the generators before Erlang, Elixir and app
compilation, whose order remains fixed. A conflicting generated filename
could change project semantics, but the resulting source still goes through
the running compiler; it cannot attest an unrelated cached BEAM.

The public regression generates actual lexer source and BEAMs in both an
owned application and its dependency, then verifies unchanged incremental
reuse. Negative controls retain missing/duplicate-stage, artifact-stage
order, alias and custom-compiler refusals. Focused suites on both gating
compilers passed 12 tests, with 3 unrelated cross-compiler exclusions.
Strict Credo, formatting and both Dialyzer checks passed.

## Remaining public-task limit

With the narrow generator allowance, `earmark_parser` generated and compiled
successfully. The same locked Oban copy then stopped with exit 2 at
`file_system`, whose pipeline is
`[:yecc, :leex, :file_system, :erlang, :elixir, :app]`.
This is a genuine custom stage; no exception was introduced.

Neither attempt produced an analysis report. No gate, fingerprint, first-run
analysis time or incremental analysis time is claimed. The original command
was not timed; it would be misleading to invent a runtime observation.
The known Oban gate in the corpus reports remains evidence from separately
qualified explicit BEAM inputs, not a successful public-task installation
in this test environment. Custom dependency compilation needs additional
production evidence before broader CI adoption.
