# Changelog

## 0.1.0

First release. `mix spec_lint` compares every exported function's `@spec`
with the signature the Elixir compiler inferred for it and reports
contradictions (errors) and undeclared return shapes (warnings), with an
ignore list in `.spec_lint.exs`. Supports Elixir 1.18 to 1.20 (and the
1.21 development branch) on OTP 27 to 29.
