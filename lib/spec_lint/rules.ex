defmodule SpecLint.Rules do
  @moduledoc """
  Registry of the rules (DESIGN.md section 4) and lookup by ID or name.

  | ID | Name | Default |
  | --- | --- | --- |
  | `SL001` | `return_conflict` | warning |
  | `SL002` | `possible_missing_return` | warning (informational) |
  | `SL003` | `spec_domain_rejected` | warning |
  | `SL004` | `possible_missing_input` | off |
  | `SL005` | `return_can_be_narrower` | off |
  | `SL006` | `possible_unexpected_return` | warning |
  | `SL007` | `spec_domain_body_warning` | off (backend unavailable) |
  | `SL008` | `analysis_unavailable` | warning |
  """

  alias SpecLint.Rules

  @rules [
    Rules.ReturnConflict,
    Rules.PossibleMissingReturn,
    Rules.SpecDomainRejected,
    Rules.PossibleMissingInput,
    Rules.ReturnCanBeNarrower,
    Rules.PossibleUnexpectedReturn,
    Rules.SpecDomainBodyWarning,
    Rules.AnalysisUnavailable
  ]

  @typedoc "A rule module (implements `SpecLint.Rule`)."
  @type rule ::
          Rules.ReturnConflict
          | Rules.PossibleMissingReturn
          | Rules.SpecDomainRejected
          | Rules.PossibleMissingInput
          | Rules.ReturnCanBeNarrower
          | Rules.PossibleUnexpectedReturn
          | Rules.SpecDomainBodyWarning
          | Rules.AnalysisUnavailable

  @doc "All rule modules, in ID order."
  @spec all() :: [rule(), ...]
  def all, do: @rules

  @doc "All rule IDs, in order."
  @spec ids() :: [String.t(), ...]
  def ids, do: Enum.map(@rules, & &1.id())

  @doc """
  Finds a rule by ID (`"SL002"`, `:SL002`) or name (`"possible_missing_return"`,
  `:possible_missing_return`), case-insensitively for IDs.
  """
  @spec find(atom() | String.t()) :: {:ok, rule()} | :error
  def find(key) when is_atom(key), do: find(Atom.to_string(key))

  def find(key) when is_binary(key) do
    key = String.trim(key)

    case Enum.find(@rules, &(&1.id() == String.upcase(key) or Atom.to_string(&1.name()) == key)) do
      nil -> :error
      rule -> {:ok, rule}
    end
  end
end
