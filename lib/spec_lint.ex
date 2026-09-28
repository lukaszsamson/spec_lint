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
    * `SpecLint.Analysis` - ties the above together for one module.
  """
end
