# Before filing anything (human checklist)

Nothing in this directory has been filed, posted or sent. Every step below
is a human action. Do them in order for each item; skip an item if a step
says so.

## For every item

1. **Re-run on current `main`.** Build Elixir at the tip of
   `elixir-lang/elixir` `main` (`bench/corpus/toolchain/build_elixir.sh
   FULL_SHA DEST` builds one pinned revision) and run the item's
   `repro.exs` with that build. The results here are for
   `648b2a9` only; a fix may have landed since. If the verdict is not
   `reproduces`, mark the draft "do not file" and stop.
2. **Search existing issues, pull requests and discussions** on
   `elixir-lang/elixir` and the `elixir-lang-core` list, open and closed.
   Suggested terms are in the table below. Link or drop the draft if it is
   a duplicate.
3. **Read `CONTRIBUTING.md` and its section "Using AI and coding agents"**
   in the Elixir repository (`AGENTS.md` is the same file). These drafts,
   the reproducers and the patch were written with an AI agent, so the
   policy applies to them. As of `648b2a9` it says, in short:
   - AI use is allowed but do not copy and paste AI-generated content into
     discussions; write your own text (translation and review help is fine).
   - Disclose AI use, and put an `Assisted-by: AGENT_NAME:MODEL_VERSION`
     tag on contributions; only the human adds `Signed-off-by`.
   - For correctness changes to the compiler or type system, a human must
     validate the finding, and the policy asks for a separate set of agents
     that argue against and try to invalidate it. The reproducers here were
     re-run on the upstream build, but no adversarial pass over the drafts'
     claims was done in this package.
   - Bug-fix pull requests need a test that fails before the fix and passes
     after; performance pull requests need a benchmark script with inputs
     and results in the description (benchee recommended).
   - Do not use agents to tackle existing issues without the "Contributions
     Welcome" label.
   Follow the venue the file asks for; the drafts note where a discussion
   suits better than an issue.
4. **Rewrite and trim the draft in your own words.** Do not paste
   `issue.md` as is. Then remove references to SpecLint, this repository's file
   paths, milestone names and internal audit numbers. Keep the smallest
   snippet that shows the difference and the expected/actual pair. Delete
   the "DRAFT, NOT FILED" banner and the local-path links.
5. **Re-run the final text.** Paste the snippet you will submit into a fresh
   file and run it on the build you cite; copy the output from that run,
   not from `results/`. Quote the build as `Elixir 1.21.0-dev (SHA)` with
   the OTP release.
6. **Decide the framing.** Bugs (list_tl, for_into_narrowing,
   subpatterns_leak) are reports. Precision and printer items are questions
   or discussions. The checker API is a feature request. Do not present a
   precision limit as a soundness bug: `dynamic()` over-approximations are
   sound.
7. **Check the attribution and licensing** of anything you attach (for
   example `for_into_narrowing/fix.patch`, a diff of a fork commit under
   your authorship, which needs the AI disclosure and `Assisted-by` line if
   an agent helped write it). Decide whether to offer a pull request instead
   of a patch file.
8. **Authorization.** Filing is a separate action (Milestone 6 is
   preparation only). Confirm who files and under which account.

## Per item

| Item | Verdict on 648b2a9 | Search terms | Extra step before filing |
| --- | --- | --- | --- |
| `for_into_narrowing` | reproduces | `for into bitstring`, `badbitbody`, `into: []` | Strongest item. Re-run on `main` first: it is the most likely to be fixed already. Run the Elixir test suite (`make test_stdlib` or the `module/types` tests) with `fix.patch` applied to a scratch clone; that was done on the fork only. |
| `list_tl` | reproduces | `list_tl`, `list difference tail`, `Descr` | Add the four-line probe as a failing test in `descr_test.exs` in a scratch clone and run it; the test text in `issue.md` was not run inside the Elixir test suite. Check `list_hd` and other projections for the dual problem before claiming it is limited to `list_tl`. Re-run the verification branch's fuzzer if you want to assert more. |
| `subpatterns_leak` | reproduces | `subpatterns`, `fresh_context`, `imprecise list guard` | Try resetting `subpatterns` in `fresh_context/1` in a scratch clone (untested): confirm the two signatures then agree and the suite still passes. |
| `helper_insensitivity` | reproduces | `local function inference`, `private function dynamic`, `specialization` | Precision request: expect a discussion, not a fix. Check the type-system roadmap and blog posts for planned call-site specialization first. Consider filing after `enum_map_result` in the same thread only if maintainers ask. |
| `enum_map_result` | reproduces | `Enum.map dynamic`, `parametric`, `higher-order`, `polymorphic` | Precision request: check whether generics or per-function special cases are planned. Keep separate from `helper_insensitivity`. |
| `fun_printing` | reproduces | `fun(2)`, `none() -> term()`, `to_quoted_string` | Ask which side is intended (printer shorthand or distinct types) rather than asserting a bug. Consider bundling with `map_top_printing` as one printer issue. |
| `map_top_printing` | reproduces | `map()` printing, `closed_map` domains | Presentation only. Confirm on `main` that domain-complete maps still print as literals. |
| `printer_load_per_map` | reproduces | `maybe_struct`, `__info__(:struct)`, `to_quoted_string` performance | Decide whether to file: the compiler rarely prints types in bulk, so upstream may see little value. Re-measure on your own machine and code path before quoting numbers; the Absinthe profile was taken on the old SpecLint and the absent-module fraction was not measured. |
| `checker_chunk_api` | gap exists | `ExCk`, `checker chunk`, `Module.Types.infer`, `clause reachability` | Feature request: start a discussion asking whether extending the chunk is acceptable before any patch. Read the current chunk version and consumers (`Module.Types.Apply`, `mix xref`, ElixirLS, `dialyzer`-style tools) so the request is precise. |

## Things this package did not do

- No network access: no issue search, no check of `main`.
- The upstream build (`648b2a9`) has untracked files from earlier
  experiments (`lib/elixir/scripts/*.exs`); no tracked file differs from the
  commit. The reproducers use only `Module.Types`, `Code` and `:beam_lib`.
- `fix.patch` was checked with `git apply --check` on `648b2a9`, not built
  or tested there.
- The first-time-load versus absent-module split of the Absinthe profile was
  not measured (see `printer_load_per_map/README.md`).
- Nothing was verified on OTP versions other than 28 (1.21 builds) and 29
  (1.20.4).
