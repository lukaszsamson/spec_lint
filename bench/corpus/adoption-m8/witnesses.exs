# Run from the pinned, compiled project copy with the campaign compiler:
# MIX_ENV=test mix run --no-start /path/to/witnesses.exs absinthe|tableau
# These are runtime witnesses, not a replacement for reading the declarations.
case System.argv() do
  ["absinthe"] ->
    inputs = [1, 1.5, nil, "text", true, [1], %{x: 1}]

    for input <- inputs do
      result = Absinthe.Blueprint.Input.parse(input)
      %{source_location: nil} = result
      IO.inspect({input, result.__struct__, result.source_location})
    end

    IO.puts("All seven native input constructors return nil source_location.")

  ["tableau"] ->
    defmodule SpecLintCampaignExtension do
      def __tableau_extension_key__, do: :campaign
    end

    {:ok, specs} = Code.Typespec.fetch_specs(Tableau.Extension)
    {{:key, 1}, clauses} = List.keyfind(specs, {:key, 1}, 0)
    true = Enum.any?(clauses, &match?({:type, _, :fun, [_, {:type, _, :atom, []}]}, &1))
    {:ok, :campaign} = Tableau.Extension.key(SpecLintCampaignExtension)
    :error = Tableau.Extension.key(Enum)
    IO.puts("An in-domain module input returns {:ok, :campaign}, outside the declared atom().")

  _ ->
    raise "expected absinthe or tableau"
end
