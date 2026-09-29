defmodule SpecLint.Compiler.Gating do
  @moduledoc """
  Separates compatibility qualification from permission to certify CI.

  Upstream 648b2a9 has a reproduced inference defect: mixed list/bitstring
  comprehensions narrow valid arguments and returns. It remains useful for
  diagnostic comparisons, but none of its findings may certify a CI gate.
  This restriction is deliberately build-wide: the bad signature can also
  affect callers. Baselines and warnings-as-errors cannot waive it.
  """

  @reason "compiler 648b2a9 is diagnostic-only: mixed list/bitstring for-into inference " <>
            "can gate correct specs; use qualified c24c235 or Elixir 1.20.4 for CI"

  @doc "Why a compatible compiler cannot certify CI, or an empty list."
  @spec reasons(map()) :: [String.t()]
  def reasons(%{revision: "648b2a9" <> _rest}), do: [@reason]
  def reasons(_capabilities), do: []

  @doc "Removes gates on diagnostic-only builds without hiding findings."
  @spec qualify([SpecLint.Issue.t()], [String.t()]) :: [SpecLint.Issue.t()]
  def qualify(issues, []), do: issues

  def qualify(issues, reasons) do
    Enum.map(issues, fn issue ->
      %{issue | gate: false, data: Map.put(issue.data, :compiler_gating_unavailable, reasons)}
    end)
  end
end
