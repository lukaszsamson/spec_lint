defmodule SpecLint.Fixtures do
  @moduledoc false
  # One function per check, plus functions that must stay silent.

  defmodule Item do
    @moduledoc false
    defstruct [:id]
    @type t :: %__MODULE__{id: integer()}
  end

  ## Errors

  @spec return_conflict(integer()) :: atom()
  def return_conflict(x), do: {:ok, x}

  @spec clause_conflict(:a | :b) :: :ok
  def clause_conflict(:a), do: :ok
  def clause_conflict(:b), do: :error

  @spec catch_all(:x | :y, keyword()) :: :ok
  def catch_all(:x, _opts), do: :ok
  def catch_all(:y, _opts), do: :nope

  @spec shadowed(nil | :other) :: :a
  def shadowed(nil), do: :a
  def shadowed(_), do: :b

  @spec dead_clause(:a | :b) :: :ok | :fine
  def dead_clause(:a), do: :ok
  def dead_clause(:b = x) when is_integer(x), do: {:error, x}
  def dead_clause(x) when is_atom(x), do: :fine

  @spec domain_rejected(atom()) :: atom()
  def domain_rejected(x) when is_integer(x), do: x

  ## Warnings

  @spec missing_return(atom()) :: {:ok, atom()} | {:error, :invalid}
  def missing_return(a), do: if(a == :blocked, do: {:error, :inactive}, else: {:ok, a})

  @spec missing_atom(integer()) :: {:ok, integer()}
  def missing_atom(n), do: if(n == 0, do: :empty, else: {:ok, n})

  @spec missing_struct(integer()) :: {:ok, integer()}
  def missing_struct(n), do: if(n == 0, do: %Item{id: 0}, else: {:ok, n})

  @spec halved(integer()) :: integer() | nil
  def halved(n) when is_integer(n), do: if(n > 0, do: n / 2, else: nil)

  @spec unexpected_return(term()) :: no_return()
  def unexpected_return(_), do: :ok

  @spec dynamic_no_return(term()) :: no_return()
  def dynamic_no_return(x), do: x

  @spec multi_clause_extra(:on) :: :off
  @spec multi_clause_extra(:off) :: :on
  def multi_clause_extra(x) when x in [:on, :off] do
    cond do
      x == :on -> :off
      x == :off -> :on
      true -> :broken
    end
  end

  ## Silent

  @spec caught(nil) :: :a
  def caught(nil), do: :a
  def caught(_), do: :b

  @spec fine(integer()) :: integer()
  def fine(x), do: x + 1

  @spec gradual_payload(map()) :: {:ok, map()}
  def gradual_payload(m), do: {:ok, Map.get(m, :x)}

  @spec halts(term()) :: no_return()
  def halts(x), do: raise(inspect(x))

  @spec unknown(term()) :: :ok
  def unknown(x), do: x

  @spec wider_spec(:a) :: :a | :b
  def wider_spec(:a), do: :a

  @spec refined(pos_integer()) :: pos_integer()
  def refined(n), do: n

  @spec correlated(x) :: x when x: atom()
  def correlated(x), do: x

  @spec user_type(Item.t()) :: Item.t()
  def user_type(%Item{} = item), do: item

  @spec multi_clause(:on) :: :off
  @spec multi_clause(:off) :: :on
  def multi_clause(x) when x in [:on, :off], do: if(x == :on, do: :off, else: :on)

  @spec widened(integer()) :: integer()
  def widened(n) when is_integer(n), do: n + Process.get(:offset, 0)

  @spec widened_payload(integer()) :: {:ok, integer()} | :error
  def widened_payload(n) when is_integer(n),
    do: if(n > 0, do: {:ok, n - Process.get(:offset, 0)}, else: :error)

  @spec multi_clause_list(0) :: []
  @spec multi_clause_list(pos_integer()) :: [:x, ...]
  def multi_clause_list(n) when is_integer(n), do: List.duplicate(:x, n)
end
