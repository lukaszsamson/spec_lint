# Independent dependency provenance review — 2026-09-30

The review exercised an isolated consumer against the working dependency
provenance fix, independently of its author's tests. No high-severity
correctness blocker remains in the scenarios below. Final source freeze,
quality gates and corpus replay are still required; this review does not
qualify publication or an unmeasured compiler/environment.

## Original failure and independent recovery

The dependency and caller use ordinary Mix projects, a path dependency and
Mix's default compiler pipeline. The consumer declares SpecLint with
`runtime: false`. There is no custom compiler or cache injection in the
original failure:

```elixir
# dependency/lib/dependency.ex
 defmodule StoredDependency do
   def value(flag, value) do
     into = if flag, do: [], else: ""
     _ = for _ <- [1], do: value, into: into
     value
   end
 end

# consumer/lib/consumer.ex
 defmodule StoredConsumer do
   @spec value(true, atom()) :: atom()
   def value(flag, value), do: StoredDependency.value(flag, value)
 end
```

Build the entire consumer normally with upstream Elixir
`648b2a94934664cfd2c788348d02d799c68faa69`, then switch to fork
`c24c23538d521d25edd6a9a7a66fc5206caab70e`, both Elixir 1.21.0-dev on
OTP 28.5.0.1. The historical task forced the owned caller but reused the
upstream dependency, producing a false SL003 gate for a call that returns
`:ok`. The updated task rebuilt the dependency before the consumer and
returned **complete, no findings, exit 0**. A clean subsequent run also
returned complete/0 and printed **no compilation or recompilation lines**.

```sh
# Set these to the two qualified compiler bin directories and source checkout.
export ASDF_ERLANG_VERSION=28.5.0.1
cd "$CONSUMER"
PATH="$ELIXIR_648_BIN:$PATH" mix compile
PATH="$ELIXIR_C24_BIN:$PATH" mix spec_lint --ci --format json --output first.json
PATH="$ELIXIR_C24_BIN:$PATH" mix spec_lint --ci --format json --output second.json
```

## Checker-only change and recorded input binding

The review saved the upstream dependency BEAM, repaired the project under
c24c235, then replaced **only** its `ExCk` chunk with the upstream chunk.
`:beam_lib.md5/1` stayed exactly
`F5FE0375B04947AAF16D383B9AE72E21` before and after the replacement. This
checks the actual inference input which a code-MD5-only check misses.

The mutation can be reproduced without changing code chunks:

```elixir
path = System.fetch_env!("DEPENDENCY_BEAM")
stale_path = System.fetch_env!("SAVED_648_BEAM")
{:ok, {_, before}} = :beam_lib.md5(String.to_charlist(path))
{:ok, _, current} = :beam_lib.all_chunks(String.to_charlist(path))
{:ok, _, stale} = :beam_lib.all_chunks(String.to_charlist(stale_path))
exck = :proplists.get_value(~c"ExCk", stale)
{:ok, binary} =
  :beam_lib.build_module(List.keyreplace(current, ~c"ExCk", 0, {~c"ExCk", exck}))
File.write!(path, binary)
{:ok, {_, after_md5}} = :beam_lib.md5(String.to_charlist(path))
true = before == after_md5
```

With compilation explicitly disabled, `SpecLint.Run.execute/3` refused the
recorded consumer: **dependency compiler artifacts changed after inference
(stored_dependency)**. Running the task rebuilt both dependency and caller,
returned complete/0, and the next clean run compiled nothing. The snapshot
prefix had no self-reference: SpecLint's dependency record had no inputs;
the test dependency referenced SpecLint; the consumer referenced both.

```sh
PATH="$ELIXIR_C24_BIN:$PATH" mix run --no-compile -e \
  'IO.inspect(SpecLint.Run.execute(SpecLint.Project.current(), %SpecLint.Config{}, ci: true))'
PATH="$ELIXIR_C24_BIN:$PATH" mix spec_lint --ci --format json --output repaired.json
PATH="$ELIXIR_C24_BIN:$PATH" mix spec_lint --ci --format json --output noop.json
```

## Other checked boundaries

- **Actual dependency environment:** a dependency function expanded
  `Mix.env()` during compilation. With the consumer built in `dev`, both
  dependency and consumer calls returned `:prod`; the report was complete/0.
  The existing valid call still returned `:ok`.
- **Cached orphan:** a valid compiled `CachedDependencyOrphan` BEAM with no
  source in the dependency was added to its ebin. The task exited 2,
  identified the unverified orphan, wrote no successful report and retained
  its bytes for explicit repair.
- **External/custom `compile: false`:** a valid pure Erlang module without
  `ExCk` was allowed, giving a complete/0 consumer result. Adding an unused
  Elixir module with malformed `ExCk` bytes `<<1, 2, 3>>` made the updated
  task refuse the dependency **before consumer inference**, exit 2, with no
  successful report. Presence of malformed Elixir metadata cannot acquire
  the pure Erlang exemption. Stripped `Elixir.*` modules also require
  provenance by the reviewed predicate.
- **Unreadable/missing dependency inventory:** the author added
  `Project.check_build_paths/1` after dependency compilation and before
  attestation. This reuses the existing missing/inventory/corrupt/filename
  checks, rather than allowing `BuildRecord.beams/1` to silently omit a file
  it cannot read. This boundary was reviewed in code; focused and full
  integration verification remains part of the author’s qualification work.
- **Compiler pipeline:** dependencies reuse the same exact built-in task,
  compiler order and alias checks as owned projects, in the dependency's
  actual environment. Dependency and owned umbrella configurations share
  those checks. No independent umbrella timing or full suite is claimed by
  this probe; those remain part of the required integration gates.

The initial malformed-chunk predicate treated decode failures as absence.
That was reported to the author and corrected to inspect raw chunk presence,
module identity and unreadability. The original remote-call mutation crashed
the compiler and exited 2; the corrected unused-module probe now exits 2
through the explicit provenance refusal instead.

## Qualification limits

Unrecorded explicit-ebin research runs still rely on externally established
compiler and dependency provenance. They cannot reconstruct who produced an
unrecorded artifact. Recorded runs now bind exact dependency input bytes;
this is stale-artifact validation in trusted projects, not a security
sandbox.

The thirty macOS corpus reports in `reports/hardening-1/` predate this fix
and are retained as a historical baseline, not current release qualification.
The Linux Absinthe consumer was killed at approximately 83 seconds in the
6 GiB container; that is a failed result, and no current Linux full-project
corpus qualification follows from it. Publication remains pending final
correctness review and qualification.
