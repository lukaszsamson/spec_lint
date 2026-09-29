defmodule CompilerCounterexamples.EnumMapResult do
  @moduledoc """
  `Enum.map/2` has no parametric signature, so its result is `dynamic()`
  whatever the element type and the mapped function return. A
  comprehension over the same list keeps the element shape.

  Shape of `Ecto.Repo.Assoc.query/4`, `Ecto.Repo.Preloader.query/7` and
  (with `Enum.reduce/3`, `Enum.into/2` and `Map.new/1`)
  `Plug.Conn.Query.decode/4` and `Plug.Conn.merge_private/2`.
  """

  # The spec says atoms; every element is a tagged tuple.
  @spec tags([atom()]) :: [atom()]
  def tags(atoms) when is_list(atoms), do: Enum.map(atoms, fn atom -> {atom, :tag} end)

  # The same function as a comprehension.
  @spec tags_for([atom()]) :: [atom()]
  def tags_for(atoms) when is_list(atoms), do: for(atom <- atoms, do: {atom, :tag})
end
