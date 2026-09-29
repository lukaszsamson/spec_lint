# Third-party source notices

SpecLint is licensed under the Apache License, Version 2.0; the full text is
in [LICENSE](LICENSE). Portions of the project derive from Elixir, also
licensed under Apache 2.0. The original notices applicable to these portions
are retained in their file headers and in [NOTICE](NOTICE):

- Copyright 2021 The Elixir Team
- Copyright 2012 Plataformatec

## Elixir source inventory

| SpecLint file | Upstream source and revision | Adaptation |
| --- | --- | --- |
| `lib/spec_lint/compiler/v1_20.ex` | [Module.Types.Apply at v1.20.4](https://github.com/elixir-lang/elixir/blob/v1.20.4/lib/elixir/lib/module/types/apply.ex), revision `759443e724f55bf58e71c0603644e99058918d52` | Copies `apply_infer/2`, clause selection and disjointness helpers into the adapter; uses the adapter interface around the application rule. |
| `lib/spec_lint/compiler/v1_21.ex` | [Module.Types.Apply at upstream 648b2a9](https://github.com/elixir-lang/elixir/blob/648b2a94934664cfd2c788348d02d799c68faa69/lib/elixir/lib/module/types/apply.ex) and [fork c24c235](https://github.com/lukaszsamson/elixir/blob/c24c23538d521d25edd6a9a7a66fc5206caab70e/lib/elixir/lib/module/types/apply.ex) | Copies the private application rule and helpers; introduces the SpecLint adapter interface and qualification. |
| `lib/spec_lint/compiler/descr_walk.ex` | [Module.Types.Descr at fork c24c235](https://github.com/lukaszsamson/elixir/blob/c24c23538d521d25edd6a9a7a66fc5206caab70e/lib/elixir/lib/module/types/descr.ex), upstream 648b2a9 and v1.20.4 | Adapts compiler layout constants and representations for SpecLint component views, bounded printing and canonicalization. The upstream Descr file credits The Elixir Team (2021). |
| `bench/body_experiment.exs` | [Module.Types at fork c24c235](https://github.com/lukaszsamson/elixir/blob/c24c23538d521d25edd6a9a7a66fc5206caab70e/lib/elixir/lib/module/types.ex) | Copies private return-clause grouping and argument-union helpers, routing type operations through SpecLint.Compiler. |
| `bench/clause_mapping/recompute.exs` | Same c24c235 `lib/elixir/lib/module/types.ex` | Instrumented copy of inference orchestration, local handlers, domain computation, grouping and context handling; records clause mappings and modes and handles undefined locals differently. The file documents the copied function inventory. |
| `bench/corpus/warnings7.patch` | Same c24c235 `lib/elixir/lib/module/types.ex` | Carries upstream context and modifies warnings to accept argument domains and return inferred local signatures. |
| `bench/upstream/for_into_narrowing/fix.patch` | [Module.Types.Expr at upstream 648b2a9](https://github.com/elixir-lang/elixir/blob/648b2a94934664cfd2c788348d02d799c68faa69/lib/elixir/lib/module/types/expr.ex) and `lib/elixir/test/elixir/module/types/expr_test.exs` | Carries upstream context, changes mixed list/bitstring comprehension inference and adds regression tests. Expr credits both original holders; ExprTest credits The Elixir Team (2021). |

The upstream license is available in the
[Elixir v1.20.4 LICENSE](https://github.com/elixir-lang/elixir/blob/v1.20.4/LICENSE).
The complete Apache 2.0 text here was taken from the qualified Elixir fork's
`LICENSES/Apache-2.0.txt`. The audited upstream files use the same license.
No upstream NOTICE file was present in the inspected Elixir source tree.

## Compiler integration and research artifacts

Other compiler-facing modules, including qualification, reachability,
translation, and `lib/spec_lint/guard_feasibility.ex`, use Elixir's compiler
interfaces or AST/type representations. The current guard feasibility code
implements SpecLint's bounded witness matcher and evaluator; the source audit
found no copied upstream implementation in that file. Calling an interface
alone is not included in the copied-code inventory above.

The source/script audit found no separately vendored non-Elixir runtime
implementation in the packaged `lib/` tree. The witness scripts
`bench/corpus/holdout_witnesses.exs`, `expansion_witnesses.exs` and
`ash_integration_witnesses.exs` call the separately fetched Ash, Req, Oban
and Splode APIs and use handwritten predicates over cited declared types.
They are research harnesses, rather than bundled copies of those libraries.

Benchmark reports may quote types, diagnostics and small code examples from
Elixir or the corpus projects identified by the benchmark manifests. Corpus
project source trees, Elixir source trees, development dependencies, compiled
artifacts and generated benchmark reports are not included in the package
archive. Those projects retain their own licenses when fetched separately.
The source repository includes research reports; its benchmark manifests
identify the originating projects and revisions.

This inventory records the identified source derivations and retained notices;
it is not a claim to third-party authorship or endorsement. The audit reviewed
tracked source/scripts/patches and explicit copy comments, compared substantial
source lines against the qualified Elixir tree, and checked the applicable
upstream headers. Similarity scanning cannot prove the absence of every
unmarked derivation or establish the authorship of original project code.
