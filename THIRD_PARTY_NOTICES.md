# Third-party source notices

SpecLint is licensed under the Apache License, Version 2.0; the full text is
in [LICENSE](LICENSE). One function derives from Elixir, also licensed under
Apache 2.0. The original notices are retained in [NOTICE](NOTICE):

- Copyright 2021 The Elixir Team
- Copyright 2012 Plataformatec

| SpecLint file | Upstream source | Adaptation |
| --- | --- | --- |
| `lib/spec_lint.ex`, `apply_infer/2` and its helpers | [Module.Types.Apply at v1.20.4](https://github.com/elixir-lang/elixir/blob/v1.20.4/lib/elixir/lib/module/types/apply.ex) | Copies the private application rule for inferred signatures so it can be applied to a spec's argument types; returns the contributing clauses instead of their indices. |

Everything else calls the compiler's `Module.Types.Descr` through its
public functions and reads the `ExCk` and debug-info chunks with the
standard `beam_lib` and `Code.Typespec` interfaces.
