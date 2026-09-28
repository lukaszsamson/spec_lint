defmodule SpecLintRepro.NearTop do
  # Reproductions for EXPERIMENTS.md, Phase 0 "Open" (near-top inference);
  # compiled and analysed by bench/triage/near_top.exs.

  # Mirrors Ecto.primary_key!/1 (lib/ecto.ex:418): the case scrutinee is a
  # dynamic remote call, so the catch-all branch returns dynamic(not []).
  @spec pk!(%{__struct__: module()}) :: [{atom(), term()}]
  def pk!(%{__struct__: schema}) do
    case schema.keys() do
      [] -> raise ArgumentError, "no keys"
      pk -> pk
    end
  end

  # Mirrors Ecto.Query.Builder.Join.escape/3: every non-recursive clause
  # returns a 5-tuple, the spec says 4-tuple; a recursive catch-all makes the
  # union top-only.
  @spec esc(term()) :: {atom(), term(), term(), list()}
  def esc(x) when is_atom(x), do: {:_, x, nil, nil, []}
  def esc(x) when is_binary(x), do: {:_, {x, nil}, nil, nil, []}
  def esc(x), do: esc(Macro.expand(x, __ENV__))
end
