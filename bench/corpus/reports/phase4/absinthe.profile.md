# Absinthe runtime profile (Fable, 2026-09-29, uncommitted Phase 4 tree)

Two measurements on the pinned Absinthe build, same VM, stack sampled every
500 ms (`bench/absinthe_profile.exs`; the per-module variant lives in the
session scratchpad):

| Stage | Time |
| --- | --- |
| `SpecLint.Analysis.module/2` over all 468 beams (translate + compare) | 37 s |
| `SpecLint.Run.execute/3` end to end (`--ci`, no rendering) | 576 s and 684 s in two runs |

So more than 90 percent of the product run is spent after analysis. The
dominant stacks are all type *printing* inside the evidence classifier:

- `SpecLint.Evidence.components/4` calls `Compiler.V121.canonical_or_complement/1`
  for every component of every slice; that function prints the type twice
  (direct and complement form) through `Descr.to_quoted_string/2` and
  `Code.Formatter` and keeps the shorter string.
- `Module.Types.Descr.map_literal_to_quoted/2` calls `maybe_struct/1`, which
  calls `:code.ensure_loaded/1` for every map literal printed; on Absinthe's
  Blueprint types that is thousands of failed module loads per slice
  (the single largest bucket, `:error_handler.undefined_function/3`).

Guard feasibility and the compiler re-check do not appear in the samples at
all. This is not a Phase 4 regression: the Phase 3 run was already 345 s.

Fix direction: classify on descr terms only and print nothing during
classification; compute component strings lazily for the findings that are
actually rendered; give fingerprints a structural canonical encoding instead
of a printed one; and report the `maybe_struct/1` load-per-print cost
upstream as a printer performance note.
