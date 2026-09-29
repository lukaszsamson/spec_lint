# checker_chunk_api

Upstream status (648b2a9): the gap exists (verdict "reproduces"). Kind:
feature request, not a bug.

The checker chunk (`ExCk`, `:elixir_checker_v10` on 648b2a9) stores, per
exported function, only `%{sig: ...}`. A consumer cannot tell which source
clause(s) a stored clause came from, nor which source clause the checker
found redundant or unreachable, except by re-running the checker and parsing
diagnostics.

Run: `elixir repro.exs`. The reproducer compiles three functions and prints
source clause counts (from the debug info), stored clause counts, the chunk
keys and the compiler diagnostics.

Source: `EXPERIMENTS.md` "Minimal compiler API", `UPSTREAM_BUGS.txt` item 4,
Milestone 4 (`bench/clause_mapping/README.md`).

## Expected vs actual

| Function | Source clauses | Stored clauses (648b2a9) | Stored (1.20.4) | In the chunk |
| --- | ---: | ---: | ---: | --- |
| `merged/1` (`:a`, `:b` return 1; `:c` returns `:x`) | 3 | 2 (`:a or :b`, `:c`) | 2 | no link from a stored clause to its sources |
| `dropped/1` (second clause always raises) | 2 | 1 | 2 (`-> none()`) | the dropped clause leaves no trace |
| `redundant/1` (clause 1 redundant) | 3 | 1 | 1 | compiler warns, chunk silent |

Chunk keys: `[:exports, :mode]`; export keys: `[:sig]`.

Expected (desired): for each function, the chunk (or a documented API) says,
per source clause, which stored clause it feeds (or that it was dropped) and a
reachability verdict: `:reachable | :redundant | :unused | :unknown`, where
`:unknown` is not proof of reachability.

## What is and is not requested

Requested (small): `group_clauses/1`, `add_inferred/5` and
`group_clauses_by_return/1` in `lib/elixir/lib/module/types.ex` already merge
and drop clauses; carrying the source clause indices through them, and
recording the redundant clause the pattern check already detects, gives the
mapping. Two invariants hold today and would become contract: each source
clause ends in at most one stored clause, and stored clause order follows the
smallest member's source index.

Why a consumer cannot reconstruct it:

- Recomputing head types is not exact. The `subpatterns` leak
  (`../subpatterns_leak/`), protocol implementations, gradual bounds widened
  by subtraction and the redundant-clause path all produce heads that differ
  from the compiler's. Only the structural cases (one source clause, or as
  many stored as source clauses) are provable from outside, and they cover
  93.5% of functions but not merged or dropped clauses.
- Block-level "no warning" is not evidence that a clause executes.

Optional, separate follow-up (from `EXPERIMENTS.md`; do not bundle with the
above): a versioned `infer_under_domains` entry point that infers only the
requested targets under caller-supplied argument domains, returns signatures
in stored form and per-clause reachability, and is discoverable with a
capability probe instead of `function_exported?/3`.

An API alone does not repair lost helper, collection or recursive return
precision (see `helper_insensitivity` and `enum_map_result`).
