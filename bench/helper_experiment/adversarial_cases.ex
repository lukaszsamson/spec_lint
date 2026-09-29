defmodule HelperExperiment.AdversarialCases do
  @moduledoc false

  # This helper's second clause is a direct return, but its guarded first
  # clause takes precedence for :bad. Summarizing the second clause is wrong.
  defp guarded(value) when value == :bad, do: :other
  defp guarded(value), do: value

  # In quoted AST, value(:bad) is a call, despite the matching parameter name.
  defp value(_arg), do: :other
  defp call_shaped(value), do: value(:bad)

  defp identity(value), do: value

  @spec guarded_public(:bad) :: :other
  def guarded_public(:bad), do: guarded(:bad)

  @spec call_shaped_public(:bad) :: :other
  def call_shaped_public(:bad), do: call_shaped(:bad)

  @spec quoted_public(:bad) :: Macro.t()
  def quoted_public(:bad), do: quote(do: identity(:bad))

  @spec captured_public(:bad) :: (-> :bad)
  def captured_public(:bad), do: fn -> identity(:bad) end
end
