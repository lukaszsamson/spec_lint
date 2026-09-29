# Tests pinned to one compiler adapter (`@tag adapter: SpecLint.Compiler.V121`)
# run only under that adapter's compiler (Milestone 3): expectations that
# legitimately differ between compiler lines are pinned per adapter, not
# loosened.
#
# The cross-compiler integration test needs another qualified compiler
# (`SPEC_LINT_OTHER_ELIXIR=/path/to/other/bin mix test --only cross_compiler`,
# README "Contributing"); without it the test is excluded, not passed.
running = SpecLint.Compiler.running_adapter()

cross_compiler =
  if System.get_env("SPEC_LINT_OTHER_ELIXIR"), do: [], else: [cross_compiler: true]

ExUnit.start(
  exclude:
    for(adapter <- SpecLint.Compiler.adapters(), adapter != running, do: {:adapter, adapter}) ++
      cross_compiler
)
