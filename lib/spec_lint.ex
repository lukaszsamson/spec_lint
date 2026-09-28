defmodule SpecLint do
  @moduledoc """
  SpecLint checks `@spec` declarations against the types the Elixir compiler
  infers.

  The core library is organised as a pipeline:

    * `SpecLint.Compiler` - the compiler adapter boundary (checker chunk
      decoding, type lattice operations, the checker's application rule);
    * `SpecLint.Beam` - reads specs, types, debug info and the checker chunk
      from one `.beam` file;
    * `SpecLint.Translate` - translates typespecs into lattice bounds with
      loss records;
    * `SpecLint.Compare` - raw per-slice relations between a translated spec
      and the inferred signature;
    * `SpecLint.Analysis` - ties the above together for one module;
    * `SpecLint.Evidence` - the `SL002` structured extra-return classifier
      over per-slice relations.

  The product around it (`mix spec_lint`, DESIGN.md sections 4, 5, 8 and 9):

    * `SpecLint.Project` - owned BEAM files of a Mix project;
    * `SpecLint.Config` and `SpecLint.CLI` - `.spec_lint.exs` and options;
    * `SpecLint.Rule` and `SpecLint.Rules` - rules `SL001` to `SL008`,
      producing `SpecLint.Issue` values;
    * `SpecLint.Policy` - CI gating by evidence and profile;
    * `SpecLint.Coverage` - the ledger and inventory;
    * `SpecLint.Baseline` - fingerprints, the baseline file and decisions;
    * `SpecLint.Run` - one run, ending in an exit code;
    * `SpecLint.Report.Console`, `SpecLint.Report.Json` and
      `SpecLint.Explain` - output.
  """
end
