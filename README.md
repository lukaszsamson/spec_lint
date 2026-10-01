# SpecLint

Checks `@spec` declarations against the type signatures the Elixir
compiler infers. Requires Elixir 1.18 or later; 1.20 infers much more
(argument types from guards and patterns), so 1.18 and 1.19 find less.

```elixir
# mix.exs (not yet published to Hex)
{:spec_lint, github: "lukaszsamson/spec_lint", only: [:dev, :test], runtime: false}
```

```
$ mix spec_lint
lib/my_app/accounts.ex:41: error: MyApp.Accounts.lookup/1: inferred return {:ok, integer()} is disjoint from the spec return atom()
    @spec lookup(integer()) :: atom()
    inferred: (integer()) -> {:ok, integer()}
lib/my_app/deposits.ex:88: warning: MyApp.Deposits.request/3: inferred return includes {:error, :merchant_inactive}, which the spec does not declare
    @spec request(t(), binary(), keyword()) :: {:ok, t()} | {:error, :not_found}
    inferred: (%MyApp.Deposit{...}, binary(), list()) -> {:ok, %MyApp.Deposit{...}} or {:error, :merchant_inactive} or {:error, :not_found}
spec_lint: 421 spec clauses checked, 1 error(s), 1 warning(s)
```

## How it works

The compiler stores an inferred signature for every function in the
`ExCk` chunk of each BEAM file. `mix spec_lint` compiles the project,
translates each spec clause into the compiler's own types, applies the
inferred signature to the spec's argument types with the compiler's own
application rule, and compares the returns. Nothing beyond the normal
compilation (and the config file) is executed; no project function is
called.

Errors are contradictions in the compiler's types:

- `return_conflict`: the inferred return is disjoint from the spec return.
- `domain_rejected`: no clause accepts the spec's arguments, so the
  compiler would warn on every conforming call.

Warnings are clauses and return values the spec does not declare:

- `clause_conflict`: a clause that accepts only spec-conforming arguments
  returns a value disjoint from the spec return. The compiler keeps
  clauses that can never match, so this is not proof.

- `missing_return`: the inferred return has a literal shape the spec
  lacks, such as an `{:error, _}` tuple, an atom or a struct the spec
  never mentions.
- `unexpected_return`: the spec says `no_return()` and the compiler
  infers a return.

Erlang `-nominal` types are read on Elixir 1.21 and treated as any
term before that; record types (`#name{}`, classic or OTP 29 native)
are any term, since the BEAM does not say which kind they are.

Inference is conservative, so an inferred type wider than the spec is
normal and silent. Values that flow straight from arguments or callbacks
are `dynamic()` to the compiler and cannot be checked; those omissions
stay silent by design.

## Options

```
mix spec_lint [--warnings-as-errors] [--format json] [--output FILE]
              [--module Mod ...] [--config FILE]
```

Exit status is 0 when there is no error (and no warning with
`--warnings-as-errors`), 1 otherwise.

## Ignoring findings

`.spec_lint.exs` in the project root:

```elixir
[
  ignore: [
    MyApp.Generated,            # a whole module
    {MyApp.Legacy, :parse},     # a function, any arity
    {MyApp.Legacy, :parse, 2},  # one function
    ~r/^MyApp\.Proto\./         # a regex on "Module.function/arity"
  ],
  warnings_as_errors: false
]
```

Specs injected by a library macro (for example Phoenix.View's
`template_not_found/2`) are reported against the module that overrides
the function; ignore them here or fix the spec upstream.

## License

Apache-2.0. `SpecLint.apply_infer/2` is a copy of a private function of
the Elixir compiler; see `THIRD_PARTY_NOTICES.md`.
