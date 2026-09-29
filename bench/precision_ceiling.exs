# Measures whether improving the translator's lower input bounds could prove
# containment for the nine omission fixtures. Run after `MIX_ENV=test mix compile`:
#
#   elixir -pa _build/test/lib/spec_lint/ebin bench/precision_ceiling.exs -- \
#     --out bench/corpus/precision_ceiling.json
#
# For each stored inferred clause I and spec slice D, D_lo ⊆ D ⊆ D_hi.
# If I ⊄ D_hi, no sound improvement to D_lo can make the *whole stored I*
# contained in D; splitting/refining I at the spec domain is a separate idea.
# If I ⊆ D_hi but I ⊄ D_lo, improving D_lo is only a possibility, not proof:
# D_hi may contain values outside the original spec.

defmodule SpecLint.PrecisionCeiling do
  @moduledoc false

  alias SpecLint.{Analysis, Bound, Compiler, Report}
  alias SpecLint.OmissionFixtures.Cases

  @functions [
    compare: 2,
    cmp: 2,
    decode: 2,
    merge_private: 2,
    apply_action: 2,
    join_escape: 3,
    quoted_type: 2,
    assoc_query: 4,
    preloader_query: 7
  ]

  @spec main([String.t()]) :: :ok
  def main(args) do
    {opts, rest, invalid} =
      OptionParser.parse(Enum.reject(args, &(&1 == "--")), strict: [out: :string])

    if rest != [] or invalid != [] or opts[:out] == nil do
      raise ArgumentError, "usage: bench/precision_ceiling.exs -- --out FILE.json"
    end

    path = Cases |> :code.which() |> List.to_string()
    result = Analysis.module(path)

    unless result.status == :ok do
      raise "fixture analysis unavailable: #{inspect(result.status)}"
    end

    functions = Map.new(result.functions, &{elem(&1.mfa, 1), &1})

    entries =
      for {name, arity} <- @functions do
        function = Map.fetch!(functions, name)
        {Cases, ^name, ^arity} = function.mfa

        %{
          mfa: "#{inspect(Cases)}.#{name}/#{arity}",
          slices: Enum.map(function.slices, &slice(&1, function.inferred))
        }
      end

    report = %{
      schema: "spec_lint/precision_ceiling",
      schema_version: 1,
      adapter: adapter_id(),
      method:
        "For every stored clause I, compare its whole argument tuple with D_lo and D_hi. I outside D_hi rules out lower-bound-only containment; I inside D_hi merely leaves it possible.",
      functions: entries,
      totals: totals(entries)
    }

    out = Path.expand(opts[:out])
    File.mkdir_p!(Path.dirname(out))
    File.write!(out, Report.Json.encode(report))
    IO.puts("wrote #{out} (#{report.totals.contributing_clauses} contributing clauses)")
    :ok
  end

  defp adapter_id do
    {:ok, capabilities} = Compiler.preflight()
    capabilities.adapter_id
  end

  defp slice(%{status: :compared} = slice, inferred) do
    d_lo = slice.args |> Enum.map(& &1.lo) |> Compiler.tuple()
    d_hi = slice.args |> Enum.map(& &1.hi) |> Compiler.tuple()
    contributing = MapSet.new(Enum.map(slice.relations.contributing, & &1.index))

    clauses =
      inferred
      |> Enum.with_index()
      |> Enum.map(fn {{args, _return}, index} ->
        clause(args, index, slice.args, d_lo, d_hi, MapSet.member?(contributing, index))
      end)

    contributing_clauses = Enum.filter(clauses, & &1.contributes)

    %{
      index: slice.index,
      input_exact: Enum.all?(slice.args, &Bound.exact?/1),
      lower_empty: Compiler.empty?(d_lo),
      lower: Compiler.to_string(d_lo),
      upper: Compiler.to_string(d_hi),
      input_losses:
        for {arg, index} <- Enum.with_index(slice.args), loss <- arg.losses do
          %{
            argument: index,
            kind: loss.kind,
            path: inspect(loss.path),
            map_field: map_field(loss.path)
          }
        end,
      clauses: clauses,
      conclusion: conclusion(contributing_clauses)
    }
  end

  defp slice(slice, _inferred), do: %{index: slice.index, status: inspect(slice.status)}

  defp clause(args, index, bounds, d_lo, d_hi, contributes?) do
    upper_args = Enum.map(args, &Compiler.upper_bound/1)
    inferred_domain = Compiler.tuple(upper_args)

    %{
      index: index,
      contributes: contributes?,
      inferred: Compiler.to_string(inferred_domain),
      intersects_upper: not Compiler.disjoint?(inferred_domain, d_hi),
      inside_upper: Compiler.subtype?(inferred_domain, d_hi),
      inside_lower: Compiler.subtype?(inferred_domain, d_lo),
      outside_upper: not Compiler.subtype?(inferred_domain, d_hi),
      arguments:
        Enum.zip_with(upper_args, bounds, fn inferred, bound ->
          %{
            inferred: Compiler.to_string(inferred),
            exact: Bound.exact?(bound),
            lower: Compiler.to_string(bound.lo),
            upper: Compiler.to_string(bound.hi),
            lower_empty: Compiler.empty?(bound.lo),
            inside_upper: Compiler.subtype?(inferred, bound.hi),
            inside_lower: Compiler.subtype?(inferred, bound.lo),
            losses: Bound.loss_kinds(bound)
          }
        end)
    }
  end

  defp map_field(path) do
    Enum.find_value(path, fn
      {:map_value, field} when is_atom(field) -> Atom.to_string(field)
      _ -> nil
    end)
  end

  defp conclusion([]), do: :no_contributing_clause

  defp conclusion(clauses) do
    cond do
      Enum.any?(clauses, & &1.inside_lower) -> :already_contained_for_some_clause
      Enum.any?(clauses, & &1.inside_upper) -> :lower_improvement_only_potentially_useful
      true -> :lower_improvement_cannot_contain_any_clause
    end
  end

  defp totals(entries) do
    slices =
      for function <- entries, slice <- function.slices, Map.has_key?(slice, :clauses), do: slice

    clauses = Enum.flat_map(slices, & &1.clauses)
    contributing = Enum.filter(clauses, & &1.contributes)

    %{
      functions: length(entries),
      slices: length(slices),
      clauses: length(clauses),
      contributing_clauses: length(contributing),
      exact_input_slices: Enum.count(slices, & &1.input_exact),
      lower_empty_slices: Enum.count(slices, & &1.lower_empty),
      contributing_inside_upper: Enum.count(contributing, & &1.inside_upper),
      contributing_inside_lower: Enum.count(contributing, & &1.inside_lower),
      contributing_outside_upper: Enum.count(contributing, & &1.outside_upper),
      slices_where_lower_alone_cannot_contain_any_clause:
        Enum.count(slices, &(&1.conclusion == :lower_improvement_cannot_contain_any_clause))
    }
  end
end

SpecLint.PrecisionCeiling.main(System.argv())
