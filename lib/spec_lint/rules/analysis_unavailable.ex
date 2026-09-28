defmodule SpecLint.Rules.AnalysisUnavailable do
  @moduledoc """
  `SL008 analysis_unavailable` (DESIGN.md sections 4 and 9).

  One issue per module that could not be analysed at all (missing debug
  info or specs metadata, unreadable BEAM) and per spec slice of an owned
  function that is `unsupported` (untranslatable construct) or
  `unavailable` (no inferred signature, unusable checker chunk).

  These are coverage findings: `SpecLint.Policy` gates them in CI unless
  the baseline inventory acknowledges the same slice with the same status.
  `SpecLint.Run` evaluates them even when SL008 is not selected, so rule
  selection never disables the coverage policy.

  A checker chunk whose version differs from the running checker's
  (DESIGN.md 5.1) has the reason `unsupported_chunk:<found version>`. It is
  a preflight failure, not a coverage gap: the run is incomplete (exit 2 in
  CI) and no inventory entry acknowledges it.
  """

  @behaviour SpecLint.Rule

  alias SpecLint.{Baseline, Issue, Rule}

  @impl true
  @spec id() :: String.t()
  def id, do: "SL008"

  @impl true
  @spec name() :: :analysis_unavailable
  def name, do: :analysis_unavailable

  @impl true
  @spec default_severity() :: :warning
  def default_severity, do: :warning

  @impl true
  @spec summary() :: String.t()
  def summary, do: "a module or spec slice could not be analysed"

  @impl true
  @spec available?() :: true
  def available?, do: true

  @doc "A short, stable text key for a status reason (for output and inventory)."
  @spec reason_key(term()) :: String.t()
  def reason_key({:checker_chunk, {:checker_version_mismatch, found, _expected}}),
    do: "unsupported_chunk:" <> key(found, 1)

  def reason_key(reason), do: key(reason, 3)

  @doc """
  Whether a status reason is an unsupported checker chunk version, a
  preflight failure rather than a coverage gap (DESIGN.md 5.1).
  """
  @spec unsupported_chunk?(term()) :: boolean()
  def unsupported_chunk?({:checker_chunk, {:checker_version_mismatch, _found, _expected}}),
    do: true

  def unsupported_chunk?(_reason), do: false

  defp key(reason, _depth) when is_atom(reason), do: Atom.to_string(reason)

  defp key(reason, depth) when is_tuple(reason) and tuple_size(reason) > 0 do
    case Tuple.to_list(reason) do
      [head, inner | _] when is_atom(head) and depth > 1 ->
        if is_atom(inner) or (is_tuple(inner) and tuple_size(inner) > 0),
          do: "#{head}:#{key(inner, depth - 1)}",
          else: Atom.to_string(head)

      [head | _] when is_atom(head) ->
        Atom.to_string(head)

      _ ->
        "other"
    end
  end

  defp key(_reason, _depth), do: "other"

  @impl true
  @spec check_module(Rule.module_context()) :: [Issue.t()]
  def check_module(%{module: %{status: {:unavailable, reason}} = result} = context) do
    module = result.module || module_from_path(result.path)
    key = reason_key(reason)

    [
      %Issue{
        rule: id(),
        name: name(),
        module: module,
        evidence: :unavailable,
        severity: context.severity,
        file: context.file,
        message: "module could not be analysed: #{key}",
        details: [{"reason", key}, {"beam", Path.basename(result.path)}],
        data: %{status: "unavailable", reason: key},
        fingerprint:
          Baseline.fingerprint(%{rule: id(), module: module, extra: {:unavailable, key}})
      }
    ]
  end

  def check_module(_context), do: []

  @impl true
  @spec check_function(Rule.function_context()) :: [Issue.t()]
  def check_function(context) do
    for %{slice: %{status: {kind, reason}} = slice} <- context.slices,
        kind in [:unsupported, :unavailable] do
      key = reason_key(reason)

      Rule.function_issue(__MODULE__, context,
        slice: slice.index,
        inferred: [],
        evidence: kind,
        fingerprint_extra: {kind, key},
        message: "spec slice is #{kind}: #{key}",
        details: [
          {"spec", Rule.spec_string(Rule.function_name(context), slice.spec)},
          {"status", "#{kind}: #{key}"}
        ],
        data: %{status: Atom.to_string(kind), reason: key}
      )
    end
  end

  defp module_from_path(path), do: path |> Path.basename(".beam") |> String.to_atom()
end
