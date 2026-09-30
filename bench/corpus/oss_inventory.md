# OSS checkout inventory (toxic2 parser corpus)

Read-only inventory of `elixir_oss/projects` (33 directories). Nothing was
compiled or modified. Revisions are abbreviated to 12 characters. No umbrella
projects exist (no `apps_path` in any root `mix.exs`); nested mix projects are
listed under the parent. "deps/ compilers" lists dependencies whose own
`mix.exs` declares `compilers:` (they apply when that dependency is compiled,
not the root project). Classification: B = built-in generator prefix (`:leex`,
`:yecc`), C = custom prefix task (`Mix.Tasks.Compile.*` from a dependency), O =
other (suffix task, conditional, or no effective change).

Corpus membership: "in" = already in SpecLint corpora (README/expansion.json/
scratchpad list), "in (stdlib source)" = the checkout is the Elixir repo used
for the stdlib corpus, though at a different revision than the pinned c24c235.
Not present in this directory although in SpecLint corpora: nimble_options,
mime, broadway, nx, tesla.

| Project | Revision | Elixir req | deps/ | mix.lock | Root compilers | Compile aliases | deps/ compilers (class) | In corpora |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| absinthe | 66cec3445d12 | ~> 1.15 | yes | yes | `[:yecc] ++ Mix.compilers()` (B) | none | earmark_parser leex,yecc (B); erlex leex,yecc (B) | in |
| aino | 2efe0889cbc3 | ~> 1.10 | yes | yes | default | none | earmark_parser (B); file_system `:file_system` (C) | no |
| ash | 164a4c0d0ef7 | ~> 1.11 | no | yes | default | aliases present, none wrap compile | n/a (no deps/) | in |
| bandit | ef3be3696c53 | ~> 1.13 | yes | yes | default | none | earmark_parser (B); erlex (B); file_system (C) | no |
| credo | a006b49aa56b | >= 1.13.0 | no | yes | default | aliases present, none wrap compile | n/a | no |
| decimal | 1414ccc0b9d7 | ~> 1.12 | yes | yes | default | none | earmark_parser (B) | in |
| ecto | 07095451d5f3 | ~> 1.14 | yes | yes | default | none | earmark_parser (B) | in |
| ecto_sql | a703c2edb90d | ~> 1.14 | yes | yes | default | aliases (test only) | earmark_parser (B) | no |
| elixir | 1b92f3ac8759 | n/a (no root mix.exs; Makefile build) | no | no | n/a | n/a | n/a | in (stdlib source) |
| gen_lsp | f73d644d6bd8 | ~> 1.11 | no | yes | default | none | n/a | no |
| gettext | e3180f138bda | ~> 1.14 | yes | yes | default | none | earmark_parser (B); expo `:yecc` (B) | no |
| guarded_struct | 24d525060c46 | ~> 1.17 | yes | yes | default | none | earmark_parser (B); ex_url `Mix.compilers()` (O) | no |
| jason | 984bc078eb4b | ~> 1.4 | yes | yes | default; nested bench/mix.exs (~> 1.6) | none | earmark_parser (B); erlex (B); jason_native `:elixir_make` (C) | in |
| kino | 2bcac29f38fa | ~> 1.14 | yes | yes | default | none | earmark_parser (B) | no |
| livebook | 1f6b12e047ad | `@elixir_requirement` | yes | yes | `[:phoenix_live_view] ++ Mix.compilers() ++ [:livebook_priv]` (C prefix + custom suffix); nested iframe (~> 1.13), proto (~> 1.14), elixirkit (~> 1.14) | aliases present, none wrap compile | earmark_parser (B); file_system (C); lazy_html `:elixir_make` (C); pythonx `:elixir_make` (C); logger_json `[]` (O) | no |
| makeup | 3e0c0379cd1c | ~> 1.12 | yes | yes | default | aliases present, none wrap compile | none | no |
| nerves_hub_link | c1399b9e7cd2 | ~> 1.14 | no | yes | default | none | n/a | no |
| nerves_hub_web | 8a37ac9f22ff | ~> 1.18.0 | no | yes | `compilers(MIX_UNUSED) ++ Mix.compilers()`: `[:phoenix_live_view]`, plus `:unused` when `MIX_UNUSED` is set (C, env-conditional) | aliases present, none wrap compile | n/a | no |
| next-ls | eb47c98eef92 | ~> 1.13 | no | yes | default | none | n/a | no |
| oban | 23fa8176b358 | ~> 1.15 | yes | yes | default | aliases present, none wrap compile | earmark_parser (B); erlex (B); exqlite `:elixir_make` (C); file_system (C) | in |
| phoenix | dab9f79496df | `@elixir_requirement` | yes | yes | default; nested installer, integration_test (~> 1.15) | `compile: [&copy_core_components/1, "compile"]` (wraps compile with a function step) | earmark_parser (B); expo `:yecc` (B) | no |
| phoenix_live_view | 517afcb3854f | ~> 1.15 | yes | yes | default | aliases present, none wrap compile | earmark_parser (B); file_system (C); lazy_html `:elixir_make` (C) | in |
| plug | e83b698aa44c | ~> 1.14 | yes | yes | default | none | earmark_parser (B) | in |
| quark | 20e7199bffae | ~> 1.11 | yes | yes | default | aliases (non-compile) | file_system (C) | no |
| req | c6e8ab1f9d1c | ~> 1.15 | yes | yes | default | aliases (non-compile) | earmark_parser (B) | in |
| spitfire | 1d728cff61f4 | ~> 1.15 | no | yes | default | none | n/a | no |
| tableau | 4922d7a2eb58 | ~> 1.15 | yes | yes | default | none | earmark_parser (B); file_system (C); floki `:leex` (B) | no |
| telemetry | 13a380ed0214 | none declared (rebar-first; mix.exs only) | no | no | default | none | n/a | no |
| timex | 5ad1b8206977 | ~> 1.11 | yes | yes | explicit `Mix.compilers()` (O, no change) | none | earmark_parser (B); erlex (B); expo `:yecc` (B) | no |
| type_class | b5316b72c7d8 | ~> 1.11 | no | yes | default | aliases present, none wrap compile | n/a | no |
| vega_lite | 5dd5dd572090 | ~> 1.12 | yes | yes | default | none | earmark_parser (B) | no |
| wallaby | 26cb3cd40223 | ~> 1.12 | no | yes | default | aliases (test.all etc.) | n/a | no |
| witchcraft | 6c61c3ecd5b4 | ~> 1.9 | no | yes | default | aliases present, none wrap compile | n/a | no |

Cohort observations:

- All 33 are git repositories. 20 have vendored deps/, 30 have mix.lock.
- Root compilers are non-default only in absinthe (yecc), livebook and
  nerves_hub_web (phoenix_live_view, plus custom suffix and env-gated `:unused`).
  Timex writes the default explicitly.
- The only compile-task alias that wraps `compile` is phoenix's
  `copy_core_components/1`.
- Dependencies' compilers seen: `:leex`/`:yecc` (built-in generators),
  `:elixir_make`, `:file_system`, `:phoenix_live_view`, `:unused`,
  `:livebook_priv` (all custom tasks). Only livebook has its own project-local
  compile task (`Mix.Tasks.Compile.LivebookPriv`, `lib/mix/tasks`).
- "Aliases present, none wrap compile" was judged by grepping the alias block
  for `compile`; it is not a full AST evaluation.
- Projects without deps/ (ash, credo, gen_lsp, nerves_hub_*, next-ls, spitfire,
  type_class, wallaby, witchcraft, telemetry) would need fetched or copied
  deps before any build.

## Proposed subset for the next public-task campaign (7)

1. phoenix: only compile alias wrapping `compile` with a function step, `@elixir_requirement`, nested installer/integration_test projects.
2. livebook: prefix `:phoenix_live_view` plus custom suffix `:livebook_priv` and a local Mix task, four nested projects, three `:elixir_make` deps.
3. nerves_hub_web: env-gated root compilers (`:unused`), strict `~> 1.18.0` requirement, no vendored deps.
4. absinthe: root built-in `:yecc` prefix (already in corpora, kept as the built-in-generator control).
5. gettext: no root compilers but an `:yecc` dependency and a large macro-generated surface.
6. tableau: default root, dependencies mix `:file_system` custom and `:leex` built-in prefixes.
7. credo: plain default config, no deps/ (only lock), large pure-Elixir codebase as the baseline.

## Untouched holdouts (3)

- bandit: default root, `:file_system` custom-prefix dependency, spec-heavy protocol code, not in any corpus.
- kino: default root, notebook-runtime macros, heavy `@spec`/behaviour use, not in any corpus.
- timex: explicit `Mix.compilers()` plus `:yecc` and `:leex` dependencies, old (~> 1.11) code, not in any corpus.
