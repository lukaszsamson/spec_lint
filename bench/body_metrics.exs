defmodule SpecLint.BodyMetrics do
  @moduledoc false

  @doc "Aggregates a finding flag across slices without treating a missing analysis as a negative."
  @spec flag([map()], atom(), atom()) :: boolean() | nil
  def flag(slices, mode, key) do
    entries = Enum.map(slices, & &1[mode])

    cond do
      Enum.any?(entries, &(is_map(&1) and Map.get(&1, key) == true)) -> true
      Enum.all?(entries, &is_map/1) -> false
      true -> nil
    end
  end

  @doc "Ground-truth outcome for a finding, with unavailable analysis outside the denominator."
  @spec outcome(boolean(), boolean() | nil) :: String.t()
  def outcome(_expected, nil), do: "unavailable"
  def outcome(true, true), do: "detected"
  def outcome(true, false), do: "suppressed"
  def outcome(false, true), do: "false_positive"
  def outcome(false, false), do: "true_negative"
end
