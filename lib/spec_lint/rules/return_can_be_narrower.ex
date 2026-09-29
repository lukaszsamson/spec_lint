defmodule SpecLint.Rules.ReturnCanBeNarrower do
  @moduledoc """
  `SL005 return_can_be_narrower` (DESIGN.md sections 3 and 4), off by
  default.

  A hint: the spec return translated exactly and the applied return is a
  strict subset of it, so the spec reserves alternatives the current
  implementation never produces. That is allowed by the contract; this is
  a tightening hint only.
  """

  @behaviour SpecLint.Rule

  alias SpecLint.Rule

  @impl true
  @spec id() :: String.t()
  def id, do: "SL005"

  @impl true
  @spec name() :: :return_can_be_narrower
  def name, do: :return_can_be_narrower

  @impl true
  @spec default_severity() :: :off
  def default_severity, do: :off

  @impl true
  @spec summary() :: String.t()
  def summary, do: "the spec return is wider than every inferred return"

  @impl true
  @spec available?() :: true
  def available?, do: true

  @impl true
  @spec check_function(Rule.function_context()) :: [SpecLint.Issue.t()]
  def check_function(context) do
    name = Rule.function_name(context)

    for %{slice: %{relations: rel} = slice} <- context.slices,
        rel != nil,
        rel.applied != :badapply,
        rel.return_exact?,
        rel.return_relation == :subset,
        not rel.top_only?,
        not rel.near_top? do
      Rule.function_issue(__MODULE__, context,
        slice: slice.index,
        evidence: :hint,
        message: "the spec return could be narrower",
        details: [
          {"spec", {:spec, name, slice.spec}},
          {"inferred return", {:type, rel.applied_upper}},
          {"never returned", {:type, rel.missing}},
          {"evidence", "hint (signature backend, #{Rule.translation_string(slice)})"}
        ]
      )
    end
  end
end
