defmodule SpecLint.Coverage do
  @moduledoc """
  The coverage ledger and inventory (DESIGN.md section 9).

  The inventory has one entry per spec slice of every in-scope function
  (`compared`, `unsupported` or `unavailable`, with the reason and whether
  the translation was exact), plus one entry per module that could not be
  analysed at all. It is what the baseline stores, so coverage policy is
  enforceable on the first run and regressions are detected per function
  and slice: losing one overload while another stays analysed is a
  regression.

  The ledger reports counts with their denominators, never a single
  percentage: modules discovered, analysed, unavailable by reason and out
  of scope by category; specs out of scope by reason (macros, protocol
  dispatch, `behaviour_info/1`, generated definitions, non-exported
  functions, excluded modules); functions and slices found, compared,
  unsupported and unavailable by reason; exact versus approximate
  translations by loss kind; signatures available and unavailable; body
  analysis requested and completed; obligations by outcome.
  """

  alias SpecLint.{Analysis, Baseline, Bound, Evidence, Issue}
  alias SpecLint.Rules.AnalysisUnavailable

  @typedoc "One inventory entry."
  @type entry :: %{
          module: String.t(),
          mfa: String.t() | nil,
          slice: non_neg_integer() | nil,
          status: String.t(),
          reason: String.t() | nil,
          translation: String.t() | nil,
          obligation: String.t() | nil,
          class: String.t() | nil
        }

  @typedoc "Evidence per slice, keyed by `{mfa, slice index}`."
  @type evidence_map :: %{optional({mfa(), non_neg_integer()}) => Evidence.classification()}

  @doc "The inventory of analysed modules, sorted."
  @spec inventory([Analysis.result()], evidence_map()) :: [entry()]
  def inventory(modules, evidence) do
    modules
    |> Enum.flat_map(&module_entries(&1, evidence))
    |> Enum.sort_by(&{&1.module, &1.mfa || "", &1.slice || -1})
  end

  defp module_entries(%{status: {:unavailable, reason}} = result, _evidence) do
    [
      %{
        module: module_name(result),
        mfa: nil,
        slice: nil,
        status: "unavailable",
        reason: AnalysisUnavailable.reason_key(reason),
        translation: nil,
        obligation: nil,
        class: nil
      }
    ]
  end

  defp module_entries(%{status: :ok} = result, evidence) do
    for function <- result.functions, slice <- function.slices do
      slice_entry(result, function, slice, Map.get(evidence, {function.mfa, slice.index}))
    end
  end

  defp module_entries(_result, _evidence), do: []

  defp slice_entry(result, function, slice, classification) do
    {status, reason} =
      case slice.status do
        :compared -> {"compared", nil}
        {kind, reason} -> {Atom.to_string(kind), AnalysisUnavailable.reason_key(reason)}
      end

    %{
      module: module_name(result),
      mfa: Issue.mfa_string(function.mfa),
      slice: slice.index,
      status: status,
      reason: reason,
      translation: translation(slice),
      obligation: obligation(slice, classification),
      class: classification && Atom.to_string(classification.class)
    }
  end

  defp module_name(%{module: nil, path: path}),
    do: path |> Path.basename(".beam") |> String.to_atom() |> inspect()

  defp module_name(%{module: module}), do: inspect(module)

  defp translation(%{status: :compared, args: args, return: return}) do
    if Enum.all?([return | args], &Bound.exact?/1), do: "exact", else: "approximate"
  end

  defp translation(_slice), do: nil

  defp obligation(%{relations: nil}, _classification), do: nil

  defp obligation(%{relations: rel}, classification) do
    cond do
      rel.applied == :badapply -> "rejected_domain"
      rel.established? -> "established"
      rel.return_relation == :disjoint and not rel.spec_return_empty? -> "conflict"
      SpecLint.Compiler.empty?(rel.extra) -> "compatible_after_approximation"
      classification == nil or classification.class in [:unknown, :none] -> "unknown"
      true -> "possible_mismatch"
    end
  end

  @doc """
  The ledger for a run. `excluded` are modules matched by `exclude`
  globs; `modules` are the analysed ones.
  """
  @spec ledger([Analysis.result()], [Analysis.result()], [entry()]) :: map()
  def ledger(modules, excluded, inventory) do
    slices = Enum.filter(inventory, & &1.slice)
    functions = modules |> Enum.flat_map(& &1.functions)
    compared = Enum.filter(slices, &(&1.status == "compared"))

    %{
      "modules" => %{
        "discovered" => length(modules) + length(excluded),
        "analysed" => Enum.count(modules, &(&1.status == :ok)),
        "unavailable" => frequencies(for(%{status: {:unavailable, r}} <- modules, do: r)),
        "out_of_scope" => %{
          "erlang_module" => Enum.count(modules, &(&1.status == {:out_of_scope, :erlang_module})),
          "excluded" => length(excluded)
        }
      },
      "specs_out_of_scope" =>
        modules
        |> Enum.flat_map(& &1.out_of_scope)
        |> Enum.map(&Atom.to_string(&1.reason))
        |> Enum.frequencies(),
      "functions" => %{
        "found" => length(functions),
        "compared" => Enum.count(functions, &(&1.status == :compared)),
        "unsupported" => Enum.count(functions, &match?({:unsupported, _}, &1.status)),
        "unavailable" => Enum.count(functions, &match?({:unavailable, _}, &1.status))
      },
      "slices" => %{
        "found" => length(slices),
        "compared" => length(compared),
        "exact" => Enum.count(compared, &(&1.translation == "exact")),
        "approximate" => Enum.count(compared, &(&1.translation == "approximate")),
        "unsupported" => reasons(slices, "unsupported"),
        "unavailable" => reasons(slices, "unavailable"),
        "loss_kinds" => loss_kinds(functions)
      },
      "signatures" => %{
        "available" => Enum.count(functions, &(&1.inferred != [])),
        "unavailable" => frequencies(for(%{status: {:unavailable, r}} <- functions, do: r))
      },
      "bodies" => %{"requested" => false, "completed" => 0},
      "obligations" =>
        compared |> Enum.map(& &1.obligation) |> Enum.reject(&is_nil/1) |> Enum.frequencies(),
      "entries" => Enum.map(inventory, &entry_json/1)
    }
  end

  defp frequencies(reasons),
    do: reasons |> Enum.map(&AnalysisUnavailable.reason_key/1) |> Enum.frequencies()

  defp reasons(slices, status),
    do:
      slices |> Enum.filter(&(&1.status == status)) |> Enum.map(& &1.reason) |> Enum.frequencies()

  defp loss_kinds(functions) do
    for function <- functions,
        %{status: :compared} = slice <- function.slices,
        kind <- [slice.return | slice.args] |> Enum.flat_map(&Bound.loss_kinds/1) |> Enum.uniq(),
        reduce: %{} do
      acc -> Map.update(acc, Atom.to_string(kind), 1, &(&1 + 1))
    end
  end

  defp entry_json(entry), do: Map.new(entry, fn {key, value} -> {Atom.to_string(key), value} end)

  @doc """
  The inventory keys (`{subject, slice}`, as `SpecLint.Baseline.inventory_key/1`)
  that regressed against the baseline inventory: a slice stored as
  `compared` that is now `unsupported` or `unavailable`, and every module
  now unavailable as a whole that had a compared slice. Slices or functions
  that no longer exist are not regressions.
  """
  @spec regressions([entry()], Baseline.t() | nil) :: MapSet.t()
  def regressions(_inventory, nil), do: MapSet.new()

  def regressions(inventory, %Baseline{inventory: stored}) do
    compared = for %{"status" => "compared"} = entry <- stored, do: entry
    compared_keys = MapSet.new(compared, &Baseline.inventory_key/1)
    compared_modules = MapSet.new(compared, & &1["module"])

    for entry <- inventory,
        entry.status != "compared",
        regressed?(entry, compared_keys, compared_modules),
        into: MapSet.new(),
        do: {entry.mfa || entry.module, entry.slice}
  end

  defp regressed?(%{mfa: nil, module: module}, _keys, modules),
    do: MapSet.member?(modules, module)

  defp regressed?(%{mfa: mfa, slice: slice}, keys, _modules),
    do: MapSet.member?(keys, {mfa, slice})
end
