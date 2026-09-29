defmodule HelperExperiment.FrozenCases do
  @moduledoc false

  # Frozen before running the experiment. Every pair is a source-level control.
  defp identity(value), do: value
  defp tagged(value), do: {:error, value}

  defp maybe_raise(value) do
    if Process.get({__MODULE__, :raise}), do: raise(ArgumentError)
    value
  end

  defp choice(value) do
    if Process.get({__MODULE__, :choice}), do: :other, else: value
  end

  defp recursive(value, 0), do: value
  defp recursive(value, n), do: recursive(value, n - 1)

  @spec identity_helper(:bad) :: :ok
  def identity_helper(:bad), do: identity(:bad)
  @spec identity_inline(:bad) :: :ok
  def identity_inline(:bad), do: :bad

  @spec tuple_helper(:bad) :: :ok
  def tuple_helper(:bad), do: tagged(:bad)
  @spec tuple_inline(:bad) :: :ok
  def tuple_inline(:bad), do: {:error, :bad}

  @spec raising_helper(:bad) :: :ok
  def raising_helper(:bad), do: maybe_raise(:bad)
  @spec raising_inline(:bad) :: :ok
  def raising_inline(:bad) do
    if Process.get({__MODULE__, :raise}), do: raise(ArgumentError)
    :bad
  end

  @spec union_helper(:bad) :: :ok
  def union_helper(:bad), do: choice(:bad)
  @spec union_inline(:bad) :: :ok
  def union_inline(:bad) do
    if Process.get({__MODULE__, :choice}), do: :other, else: :bad
  end

  @spec recursive_helper(:bad) :: :ok
  def recursive_helper(:bad), do: recursive(:bad, 1)
  @spec recursive_inline(:bad) :: :ok
  def recursive_inline(:bad), do: :bad

  @spec multi_helper(:left | :right) :: :ok
  def multi_helper(:left), do: identity(:left)
  def multi_helper(:right), do: identity(:right)
  @spec multi_inline(:left | :right) :: :ok
  def multi_inline(:left), do: :left
  def multi_inline(:right), do: :right

  @spec repeated_helper(:bad) :: :ok
  def repeated_helper(:bad), do: {identity(:bad), identity(:bad), identity(:bad)}
  @spec repeated_inline(:bad) :: :ok
  def repeated_inline(:bad), do: {:bad, :bad, :bad}
end
