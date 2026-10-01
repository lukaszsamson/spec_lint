# SpecLint

Checks `@spec` declarations against the type signatures the Elixir
compiler infers. Tested on Elixir 1.18–1.20; Elixir 1.21 support is
experimental. Requires Elixir 1.18 or later; 1.20 infers much more
(argument types from guards and patterns), so 1.18 and 1.19 find less.

```elixir
# mix.exs
{:spec_lint, "~> 0.1", only: [:dev, :test], runtime: false}
```

```
$ mix spec_lint
lib/my_app/accounts.ex:41: error: MyApp.Accounts.lookup/1: inferred return {:ok, term()} is disjoint from the spec return atom()
    @spec lookup(integer()) :: atom()
    inferred: (term()) -> dynamic({:ok, term()})
lib/my_app/deposits.ex:88: warning: MyApp.Deposits.request/3: inferred return includes {:error, :merchant_inactive}, which the spec does not declare
    @spec request(t(), binary(), keyword()) :: {:ok, t()} | {:error, :not_found}
    inferred: (%MyApp.Deposit{status: :inactive}, binary(), term()) -> {:error, :merchant_inactive}
    inferred: (%MyApp.Deposit{status: :active}, binary(), term()) -> dynamic({:ok, term()} or {:error, :not_found})
spec_lint: 421 spec clauses checked, 1 error(s), 1 warning(s)
```

## How it works

The compiler stores inferred signatures in the `ExCk` chunk of each BEAM
file. Analysis covers exported functions with readable specs and stored
inferred signatures in the current application, or owned applications in
an umbrella. Dependencies and private functions are excluded.
`mix spec_lint` compiles the project,
translates each spec clause into the compiler's own types, applies the
inferred signature to the spec's argument types with the compiler's own
application rule, and compares the returns. Nothing beyond the normal
compilation (and the config file) is executed; no project function is
called.

Errors are contradictions in the compiler's types:

- `return_conflict`: the inferred return is disjoint from the spec return.
- `domain_rejected`: no clause accepts the spec's arguments, so the
  compiler would warn on every conforming call.

Warnings indicate possible mismatches, not proven runtime behavior:

- `clause_conflict`: a clause that accepts only spec-conforming arguments
  returns a value disjoint from the spec return. The compiler keeps
  clauses that can never match, so this is not proof.

- `missing_return`: the inferred return has a literal shape the spec
  lacks, such as an `{:error, _}` tuple, an atom or a struct the spec
  never mentions.
- `unexpected_return`: the spec says `no_return()` and the compiler
  infers a return.

Spec clauses that use a construct the translator cannot read (a `when`
constraint other than `x :: type`) are skipped and counted. Erlang
`-nominal` types are read on Elixir 1.21 and treated as any term before
that; record types (`#name{}`, classic or OTP 29 native) are any term,
since the BEAM does not say which kind they are.

Inference is conservative, so an inferred type wider than the spec is
normal and silent. Values that flow straight from arguments or callbacks
are `dynamic()` to the compiler and cannot be checked; those omissions
stay silent by design. Silence does not establish that a spec is correct.

## Options

```
mix spec_lint [--warnings-as-errors] [--format json] [--output FILE]
              [--module Mod ...] [--config FILE]
```

Exit status is 0 when there is no error (and no warning with
`--warnings-as-errors`), 1 otherwise.

The format is `console` (default) or `json`. JSON requires `--output FILE`:

```
mix spec_lint --format json --output findings.json
```

The file is a machine-readable JSON array of findings; compilation messages
and the summary stay on the console. Each finding has `severity` (`error`
or `warning`), `check`, `module`, `function`, `arity`, `file`, `line`,
`message`, `spec` and `inferred`. Module, function and check names are
strings; `arity` is an integer, `file` is a string or null, `line` is an
integer or null, and `spec`
and `inferred` are arrays of strings. An empty result is `[]`.

Repeat `--module Mod` to select project modules; unmatched names are usage
errors. `--config FILE` selects an executable Elixir configuration file.
`--no-warnings-as-errors` overrides a true configuration value.
Unknown formats, options and positional arguments are rejected.

The supported public interfaces are this Mix task, its configuration, and
the JSON findings file. The programmatic `SpecLint` API and compiler
translator helpers are internal and unstable.

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

Ignore entries match findings by exact module/function/arity as shown, or
by regex against the displayed `Module.function/arity` string (without an
`Elixir.` prefix). Ignoring removes findings before severity totals and
exit status are calculated. The checked count is successfully compared
spec clauses, not functions or findings; ignored findings do not reduce
it. The skipped count is spec clauses that could not be translated or
compared, and may count multiple clauses of one function.

Specs injected by a library macro (for example Phoenix.View's
`template_not_found/2`) are reported against the module that overrides
the function; ignore them here or fix the spec upstream.

## Development

```
mix test
mix credo --strict
mix format --check-formatted
mix docs --warnings-as-errors
```

CI runs the suite on Elixir 1.18 (OTP 27), 1.19 (OTP 28) and 1.20
(OTP 28 and 29). `UPSTREAM_BUGS.txt` records the library spec mistakes
and compiler precision limits found while building the tool.

## License

Apache-2.0. <code>SpecLint.apply_infer/2</code> is a copy of a private function of
the Elixir compiler; see `THIRD_PARTY_NOTICES.md`.
