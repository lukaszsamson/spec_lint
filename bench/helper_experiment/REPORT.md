# Bounded helper-return investigation

Date: 2026-09-29. Toolchain: local Elixir 1.21.0-dev `c24c23538d521d25edd6a9a7a66fc5206caab70e`, checker `elixir_checker_v10`, OTP 28. This is the already qualified fork, not current unmodified upstream. No compiler checkout or SpecLint production code was edited.

Run from the repository root:

```sh
elixir bench/corpus/compiler_counterexamples/check.exs
elixir bench/helper_experiment/run.exs
elixir bench/helper_experiment/prototype.exs
elixir bench/helper_experiment/prototype.exs bench/helper_experiment/adversarial_cases.ex
```

`frozen_cases.ex` was written and run before developing `prototype.exs`. It contains paired helper and inline controls for identity, tuple wrapping, a raising branch, a union branch, recursion, two call domains, and three repeated calls. All inputs and omitted returns are synthetic. Existing Ash, Nx, Absinthe, Tesla, and other corpus results are observed; this is **not** a fresh holdout or a new independently witnessed real-library detection.

After adversarial review, `adversarial_cases.ex` was added before fixing the prototype's eligibility checks. It exercises a guarded clause followed by a direct-return clause, a call expression whose name matches a parameter, quoted code, and a closure. The prototype now counts guarded and plain private clauses together, recognizes a variable only when its AST metadata/context have variable shape, and leaves entire public bodies containing quote or capture syntax untouched. The adversarial run asserts that only `identity/1` receives a summary and verifies the four public runtime results.

## Baseline and prototype

The baseline `ExCk` signatures below were read directly from the compiler. The prototype parses the frozen source and substitutes calls only to a private, one-clause, guardless, arity-one helper whose body is exactly its parameter or a two-element tuple containing that parameter once and a literal in the other position. It then runs the same pinned compiler on the transformed module. It is a source transformation proof of concept, not a compiler patch, SpecLint finding, or qualified adapter build.

| Case | Baseline helper return | Inline return | Prototype helper return |
| --- | --- | --- | --- |
| Identity | `dynamic()` | `:bad` | `:bad` |
| Tuple wrapper | `dynamic({:error, term()})` | `{:error, :bad}` | `{:error, :bad}` |
| Raising or return | `dynamic()` | `:bad` | `dynamic()` |
| Union or return | `dynamic()` | `dynamic(:bad or :other)` | `dynamic()` |
| Recursive | `dynamic()` | `:bad` | `dynamic()` |
| Two call domains | one `(:left or :right) -> dynamic()` arrow | separate `:left` and `:right` arrows | same two arrows as inline |
| Three repeated calls | `dynamic({term(), term(), term()})` | `{:bad, :bad, :bad}` | `{:bad, :bad, :bad}` |

The prototype asserts exact equality with the inline `ExCk` clauses for identity, tuple, multiple-domain, and repeated-call pairs. It deliberately excludes branching, recursion, and raising. The inline union control itself remains gradual because its `Process.get/1` condition is dynamic. The standalone `sign(:nan)` example remains `dynamic()` through `handle_error/2`; this prototype does **not** recover it because that helper can raise and has a branch. Thus the measured new real-library detections are **zero**.

## Compiler insertion point and limits

In `Module.Types`, `local_handler/5` memoizes one signature in `context.local_sigs` for each `{name, arity}`. The callee body is inferred under the default domain; `Module.Types.Apply.local/7` then reads that signature and `apply_infer/2` combines matching returns, wrapping them in `dynamic()`. A direct-return helper therefore loses the relationship between its caller's argument and return. The existing `@max_clauses 16` limit already bounds matching inferred arrows. A native parametric summary would have to preserve argument occurrence and result structure through `local_handler` and substitute at local call application; expanding the stored `ExCk` format or silently substituting a new compiler into SpecLint would require separate qualification.

This prototype is narrowly sound for return values when its recognized body has one occurrence of its parameter: call arguments are evaluated once and the helper has no guards, branches, recursion, or extra effects. It does not model exceptions, stack traces, macros, defaults, overloaded clauses, captures, or arbitrary tuple nesting. It rejects overloaded helpers, including guarded clauses, and avoids rewriting within any public body containing quote or capture syntax. Raising helpers such as the motivating Decimal example need a richer summary of normal-return paths and a proof that the raising branch cannot return. That is the next specific compiler research question; direct substitution alone is insufficient for the current motivating corpus miss.

Five separate-process compilation samples of the frozen module: baseline `32.7–34.5 ms` (median `33.7 ms`); transformed `27.3–30.6 ms` (median `28.2 ms`). These are tiny samples with different source text, unused-private-function warnings after transformation, and no compiler integration cost. They only show that the prototype runs quickly on this fixture; they do not establish a performance improvement or a scalable bound. The three-call case checks repeated uses functionally, not large-module throughput.

The current unmodified upstream revision was not tested. The `~/elixir` checkout remains pinned at `c24c235`, and this work did not fetch or alter it. The existing counterexample script was rerun successfully on the pinned toolchain: `sign(:nan)` stays `dynamic()`, `sign_inline(:nan)` retains `{:error, :nan}`, and the runtime witnesses pass.

Final integrated validation: all four scripts above pass, as do 322 tests,
full strict Credo, formatting, Dialyzer (zero errors), and the self CI check
(277 specs, exit 0). Experimental results remain separate from product findings.
