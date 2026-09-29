# printer_load_per_map

Upstream status (648b2a9): reproduces. Kind: performance / side effect of
the type printer.

`Module.Types.Descr.to_quoted_string/2` prints a closed map literal through
`map_literal_to_quoted/2`. When the map has a single-atom `:__struct__` field
it calls `maybe_struct/1`, i.e. `struct.__info__(:struct)` inside
`try/rescue`, on every print. If the module is loaded that is cheap. If it
is not loadable, each print performs a failed module load through
`:error_handler.undefined_function/3` and the code server, and the cost
grows with the length of the code path.

Run: `elixir repro.exs`. Needs 1.21 (`not applicable` on 1.20).

Source: `absinthe.profile.md` in this directory (a copy of
`bench/corpus/reports/phase4/absinthe.profile.md`, the Phase 4 profile) and
the Milestone 1 review in `STATUS.md`. `UPSTREAM_BUGS.txt` does not list it.

## Expected vs actual

Reproducer output on 648b2a9 (`results/upstream-648b2a9/printer_load_per_map.txt`;
the timings vary between runs and machines, shown here as the range of three
runs, while the call counts do not):

| Case | Code path 43 | 143 | 443 | undefined_function calls per 2000 prints |
| --- | ---: | ---: | ---: | ---: |
| plain map | 7 us | 6 us | 6 us | 0 |
| struct, module loaded | 6 us | 6 us | 6 us | 0 (1 on first print) |
| struct, module absent | 24-73 us | 377-667 us | 1.5-2.7 ms | 2000 |

Expected: printing a type has no per-print module-loading cost, or at
least a repeated print of the same absent module does not go back to the
code server each time (and printing does not load modules as a side effect).
Actual: one failed load per print.

The extra code path entries are empty synthetic directories standing for the
`ebin` directories of a project's dependencies; the growth with path length is
the point, the absolute numbers are not a real project's.

## What the Absinthe profile does and does not show

`absinthe.profile.md`: SpecLint over the pinned Absinthe build took 576 s and
684 s end to end (`--ci`), against 37 s for translation and comparison, and
the dominant stacks are type printing. `maybe_struct/1`'s module load,
`:error_handler.undefined_function/3`, was the single largest bucket.
Caveats a maintainer will ask about:

- SpecLint itself printed each component twice; Milestone 1 removed
  printing from classification (`Run.execute/3` went from 576-684 s to
  60-67 s on Absinthe, `STATUS.md` "Milestone 1"). The total in the profile
  is inflated by our own usage; it is evidence that the load is hot, not
  that printing is 90 percent of a normal compile.
- A second observation from the Milestone 1 review (`STATUS.md`,
  "Milestone 1 review"): after that change, JSON rendering in the run
  process varied from 1 s to 78 s. Cause: printing a map type loads the
  module of every struct it prints (`maybe_struct/1`), and each code load in
  a process holding about 3.3 GB of analysis results took seconds. Rendering
  in a short-lived process brought it to 0.13-0.17 s. So the load is also
  sensitive to the heap of the printing process.
- The profile did not separate absent modules from first-time loads of
  present ones. The standalone reproducer isolates the absent-module case,
  which is the one that repeats per print; the fraction of Absinthe's failed
  loads that were absent modules was not measured.
- The compiler itself rarely prints types in bulk, so the practical impact
  upstream may be small; tools built on `to_quoted_string/2` feel it.
