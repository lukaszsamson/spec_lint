defmodule SpecLint.InheritedSpec do
  @moduledoc """
  Heuristically flags a spec that may not have been written next to its definition, such as one injected
  by a macro, typically a library's `__using__/1` that emits
  `@spec f(...) :: ...`, `def f(...)` and `defoverridable f: n`, after which
  the application overrides `f`.

  The only observable signal is the annotation of the spec in the debug
  chunk (`Code.Typespec.fetch_specs/1`, DESIGN.md section 8). A spec written
  in the module's source carries `{line, column}` when the compiler runs
  with columns; the same spec produced by a `quote` block that is expanded
  in the module carries a bare line, the line of the macro call (the `use`
  line), and no column. `quote location: :keep` does not change this: the
  spec still carries the bare line of the call. The detection therefore
  requires evidence that columns were on: the function's own definition
  carries a `:column`. When it does not (columns off), nothing can be said
  and the result is `:not_detected`, never a guess.

  A spec the module builds itself from an AST without line metadata
  (`Code.string_to_quoted!/1` or `quote` evaluated in the module body with
  `Code.eval_quoted/3`, or a quoted spec read from another file) also
  carries a bare line, but that line is not a macro call in the module:
  it is the default line 1 of the AST. A macro call lies inside the module
  body, after its `defmodule` line, so a bare line that is not after the
  module's `defmodule` line (or a module whose line is unknown) is
  `:not_detected`. Such a spec whose AST carries a line inside the module
  cannot be told apart from an injected one. This source-location heuristic
  cannot prove macro injection or identify a library as the spec's owner.

  The macro that did the injection is not recorded in the BEAM, so it is
  not reported, and the line is presented as "reported line".

  Only `data` and the explanation are affected. Gating, evidence classes
  and fingerprints never read this.
  """

  @typedoc """
  What is known about the function whose spec is examined: whether its
  definition has a column and the `defmodule` line of its module
  (`SpecLint.Analysis.function_result/0`).
  """
  @type origin :: %{
          required(:definition_column?) => boolean(),
          required(:module_line) => pos_integer() | nil,
          optional(term()) => term()
        }

  @doc """
  Whether the annotation of `spec` (a `Code.Typespec.fetch_specs/1` entry)
  resembles macro injection. This cannot prove the spec's origin. Returns
  `{:possibly_inherited, line}` or `:not_detected`.
  """
  @spec detect(tuple() | term(), origin()) ::
          {:possibly_inherited, pos_integer()} | :not_detected
  def detect({:type, line, kind, _}, %{definition_column?: true, module_line: module_line})
      when kind in [:fun, :bounded_fun] and is_integer(line) and is_integer(module_line) and
             line > module_line,
      do: {:possibly_inherited, line}

  def detect(_spec, _origin), do: :not_detected

  @doc "The sentence added to a finding's details when the spec resembles macro injection."
  @spec note(pos_integer()) :: String.t()
  def note(line) do
    "this spec may not be written next to the definition: its source-location pattern " <>
      "resembles macro injection (reported line #{line}, often the macro call such as `use`). " <>
      "This is heuristic; inspect the spec and its source before deciding how to address it."
  end
end
