defmodule SpecLint.Rules.PossibleUnexpectedReturn do
  @moduledoc """
  `SL006 possible_unexpected_return` (DESIGN.md sections 3 and 4).

  The spec return is empty (`no_return()` or `none()`) but inference
  predicts a normal return. Inference does not prove returnability, so this
  is review evidence: reported in both profiles, gated in `review`. A
  top-only or near-top applied return is not evidence and is left to the
  ledger.
  """

  @behaviour SpecLint.Rule

  alias SpecLint.{Compiler, Rule}

  @impl true
  @spec id() :: String.t()
  def id, do: "SL006"

  @impl true
  @spec name() :: :possible_unexpected_return
  def name, do: :possible_unexpected_return

  @impl true
  @spec default_severity() :: :warning
  def default_severity, do: :warning

  @impl true
  @spec summary() :: String.t()
  def summary, do: "a no_return() spec whose implementation may return normally"

  @impl true
  @spec available?() :: true
  def available?, do: true

  @impl true
  @spec check_function(Rule.function_context()) :: [SpecLint.Issue.t()]
  def check_function(context) do
    name = Rule.function_name(context)

    for %{slice: %{relations: rel} = slice} <- context.slices,
        rel != nil,
        rel.spec_return_empty?,
        rel.applied != :badapply,
        not Compiler.empty?(rel.applied_upper),
        not rel.top_only?,
        not rel.near_top? do
      Rule.function_issue(__MODULE__, context,
        slice: slice.index,
        evidence: :unexpected_return,
        message: "the spec says no normal return, but inference predicts one",
        details: [
          {"spec", Rule.spec_string(name, slice.spec)},
          {"inferred return", Compiler.to_string(rel.applied_upper)},
          {"slice", Rule.domain_string(slice.args)},
          {"evidence", "unexpected_return (signature backend; not a reachability proof)"}
        ]
      )
    end
  end
end
