# Tests pinned to one compiler adapter (`@tag adapter: SpecLint.Compiler.V121`)
# run only under that adapter's compiler (Milestone 3): expectations that
# legitimately differ between compiler lines are pinned per adapter, not
# loosened.
running = SpecLint.Compiler.running_adapter()

ExUnit.start(
  exclude:
    for(adapter <- SpecLint.Compiler.adapters(), adapter != running, do: {:adapter, adapter})
)
