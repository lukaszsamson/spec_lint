defmodule SpecLint.Policy do
  @moduledoc """
  CI policy by evidence (DESIGN.md sections 4, 8 and 9), independent of a
  rule's severity.

  | Finding | `soundness` | `review` |
  | --- | --- | --- |
  | SL001 `conflict` / `clause_conflict`, prerequisites met | gate | gate |
  | SL003, prerequisites met | gate | gate |
  | SL002 (every evidence class) | report | report |
  | SL006 | report | gate |
  | SL004, SL005 hints | report | report |
  | SL008 coverage | gate | gate |

  An `:unchecked` prerequisite (clause reachability) does not block; a
  `:blocked` one does. SL008 gates unless the baseline inventory
  acknowledges it (`SpecLint.Baseline`); a coverage regression gates only
  with `coverage: [fail_on_regression: true]` (the default).
  `warnings_as_errors` gates every reported finding, overriding the
  evidence prerequisites. Gating only fails a run in CI mode or with
  `warnings_as_errors`.
  """

  alias SpecLint.{Config, Issue}

  @doc """
  Sets `gate` on each issue for the configuration. `regressions` is the set
  of SL008 subjects that regressed (`SpecLint.Coverage.regressions/2`);
  their issues get `data.regression = true`.
  """
  @spec apply_gates([Issue.t()], Config.t(), MapSet.t()) :: [Issue.t()]
  def apply_gates(issues, %Config{} = config, regressions) do
    Enum.map(issues, fn issue ->
      issue = mark_regression(issue, regressions)
      %{issue | gate: config.warnings_as_errors or gate?(issue, config)}
    end)
  end

  defp mark_regression(%Issue{rule: "SL008"} = issue, regressions) do
    if MapSet.member?(regressions, {Issue.subject(issue), issue.slice}),
      do: %{issue | data: Map.put(issue.data, :regression, true)},
      else: issue
  end

  defp mark_regression(issue, _regressions), do: issue

  @doc "Whether an issue gates under the evidence policy (ignoring `warnings_as_errors`)."
  @spec gate?(Issue.t(), Config.t()) :: boolean()
  def gate?(%Issue{rule: "SL001", evidence: evidence} = issue, _config)
      when evidence in [:conflict, :clause_conflict],
      do: Issue.prerequisites_met?(issue)

  def gate?(%Issue{rule: "SL003"} = issue, _config), do: Issue.prerequisites_met?(issue)
  def gate?(%Issue{rule: "SL006"}, %Config{profile: profile}), do: profile == :review

  def gate?(%Issue{rule: "SL008", data: %{regression: true}}, %Config{coverage: coverage}),
    do: coverage.fail_on_regression

  def gate?(%Issue{rule: "SL008"}, _config), do: true
  def gate?(%Issue{}, _config), do: false

  @doc """
  Why the evidence policy does or does not gate an issue, for `--explain`
  and the console report.
  """
  @spec explain(Issue.t(), Config.t()) :: String.t()
  def explain(%Issue{} = issue, %Config{} = config) do
    cond do
      config.warnings_as_errors ->
        "gates: --warnings-as-errors gates every reported finding"

      gate?(issue, config) ->
        "gates in the #{config.profile} profile"

      Issue.blocked(issue) != [] and issue.rule in ["SL001", "SL003"] ->
        "reported, not gated: prerequisites blocked: " <>
          Enum.map_join(Issue.blocked(issue), ", ", &Atom.to_string/1)

      issue.rule == "SL002" ->
        "reported, not gated: SL002 is informational (Phase 0 and Phase 1 decisions)"

      issue.rule == "SL006" ->
        "reported, not gated: SL006 gates only in the review profile"

      issue.rule == "SL008" ->
        "reported, not gated: coverage regressions do not fail (fail_on_regression: false)"

      true ->
        "reported, not gated: #{issue.evidence} evidence is report-only"
    end
  end
end
