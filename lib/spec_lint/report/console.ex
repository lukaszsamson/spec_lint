defmodule SpecLint.Report.Console do
  @moduledoc """
  The console report (DESIGN.md section 4): a header, one block per
  finding, then the coverage ledger with denominators, baseline decisions
  and the result.

  ```
  lib/store.ex:12: SL002 possible_missing_return Store.lookup/1 slice 0 [warning]
    spec:            lookup(:present | :missing) :: {:ok, integer()}
    inferred extra:  {:error, :missing}
    slice:           (:present | :missing)
    evidence:        structured_possible (signature backend, translation exact)
    Review whether the spec should include this alternative.
    policy:          reported, not gated: SL002 is informational (...)
  ```

  The header line names the rule, the subject, the spec slice, the inferred
  clause for a per-clause finding (` clause #1`) and the severity. The
  `policy:` line says whether the finding gates and why, and its baseline
  state. The run header names the adapter, the profile, the mode, a
  partial run and `expand_opaque` when it is on.

  Types are printed through the adapter; printed strings are presentation
  only.
  """

  alias SpecLint.{Issue, Policy, Run}

  @doc "Renders a finished run."
  @spec render(Run.t()) :: iolist()
  def render(%Run{} = run) do
    [
      header(run),
      Enum.map(run.issues, &issue(&1, run)),
      ledger(run),
      baseline(run),
      result(run)
    ]
  end

  @doc "Renders one issue."
  @spec issue(Issue.t(), Run.t()) :: iolist()
  def issue(%Issue{} = issue, %Run{} = run) do
    location =
      case {issue.file, issue.line} do
        {nil, _} -> "nofile"
        {file, nil} -> file
        {file, line} -> "#{file}:#{line}"
      end

    slice = if issue.slice, do: " slice #{issue.slice}", else: ""
    clause = if issue.clause, do: " clause ##{issue.clause}", else: ""
    width = issue.details |> Enum.map(&String.length(elem(&1, 0))) |> Enum.max(fn -> 0 end)
    width = max(width + 2, 17)

    details =
      for {label, value} <- issue.details do
        ["  ", String.pad_trailing(label <> ":", width), value, "\n"]
      end

    [
      location,
      ": ",
      issue.rule,
      " ",
      Atom.to_string(issue.name),
      " ",
      Issue.subject(issue),
      slice,
      clause,
      " [#{issue.severity}]\n",
      details,
      "  ",
      issue.message,
      "\n",
      "  ",
      String.pad_trailing("policy:", width),
      status(issue, run),
      "\n\n"
    ]
  end

  defp status(issue, run) do
    base = Policy.explain(issue, run.config)

    case {issue.baseline, Issue.blocking?(issue), run.ci? or run.config.warnings_as_errors} do
      {:baselined, _, _} -> base <> " (baselined)"
      {:expired, _, _} -> base <> " (baseline entry expired)"
      {_, true, true} -> base <> " (new: fails this run)"
      {_, true, false} -> base <> " (new; fails with --ci)"
      _ -> base
    end
  end

  defp header(run) do
    caps = run.capabilities || %{}
    mode = if run.ci?, do: "CI", else: "local"

    [
      "SpecLint #{Run.tool_version()} (adapter #{caps[:adapter_id] || "unavailable"}, ",
      "OTP #{System.otp_release()}), profile #{run.config.profile}, #{mode}",
      if(run.partial?, do: ", partial run", else: ""),
      if(run.config.expand_opaque, do: ", expand_opaque (opaque types expanded)", else: ""),
      "\n\n"
    ]
  end

  defp ledger(%Run{ledger: ledger}) when map_size(ledger) == 0, do: []

  defp ledger(%Run{ledger: ledger}) do
    modules = ledger["modules"]
    functions = ledger["functions"]
    slices = ledger["slices"]

    [
      "Coverage:\n",
      "  modules: #{modules["discovered"]} discovered, #{modules["analysed"]} analysed, ",
      "#{count(modules["unavailable"])} unavailable#{reasons(modules["unavailable"])}, ",
      "#{modules["out_of_scope"]["erlang_module"]} Erlang, ",
      "#{modules["out_of_scope"]["excluded"]} excluded\n",
      "  functions: #{functions["found"]} found, #{functions["compared"]} compared, ",
      "#{functions["unsupported"]} unsupported, #{functions["unavailable"]} unavailable\n",
      "  slices: #{slices["found"]} found, #{slices["compared"]} compared ",
      "(#{slices["exact"]} exact, #{slices["approximate"]} approximate), ",
      "#{count(slices["unsupported"])} unsupported#{reasons(slices["unsupported"])}, ",
      "#{count(slices["unavailable"])} unavailable#{reasons(slices["unavailable"])}\n",
      "  obligations: #{pairs(ledger["obligations"])}\n",
      unknown_reasons(ledger["obligations_unknown_by_reason"]),
      expanded(slices["expanded"]),
      "  specs out of scope: #{pairs(ledger["specs_out_of_scope"])}\n",
      "  body analysis: not requested (signature backend only)\n",
      if(slices["found"] == 0, do: "  no eligible specs found\n", else: []),
      "\n"
    ]
  end

  defp unknown_reasons(map) when map_size(map) == 0, do: []
  defp unknown_reasons(map), do: "  unknown obligations by reason: #{pairs(map)}\n"

  defp expanded(0), do: []

  defp expanded(count),
    do: "  translations with opaque or nominal types expanded (expand_opaque): #{count}\n"

  defp count(map), do: map |> Map.values() |> Enum.sum()

  defp reasons(map) when map_size(map) == 0, do: ""
  defp reasons(map), do: " (" <> pairs(map) <> ")"

  defp pairs(map) when map_size(map) == 0, do: "none"

  defp pairs(map) do
    map
    |> Enum.sort_by(fn {key, value} -> {-value, key} end)
    |> Enum.map_join(", ", fn {key, value} -> "#{key} #{value}" end)
  end

  defp baseline(run) do
    decisions = run.baseline_decisions
    baselined = Enum.count(run.issues, &(&1.baseline == :baselined))

    head =
      case decisions.reason do
        :missing ->
          "Baseline: none (#{run.config.baseline} not found)\n"

        :adapter_mismatch ->
          "Baseline: #{run.config.baseline} NOT applied: written by adapter " <>
            "#{run.baseline.adapter}\n"

        nil ->
          "Baseline: #{run.config.baseline} applied, #{baselined} finding(s) acknowledged\n"
      end

    stale =
      for entry <- decisions.stale_findings do
        "  stale finding: #{entry["rule"]} #{entry["mfa"]} slice #{entry["slice"]} " <>
          "(#{entry["fingerprint"]})\n"
      end

    stale_inventory =
      for entry <- decisions.stale_inventory do
        "  stale acknowledgement: #{entry["mfa"] || entry["module"]} slice #{entry["slice"]} " <>
          "(#{entry["status"]})\n"
      end

    [head, stale, stale_inventory, "\n"]
  end

  defp result(run) do
    blocking = Enum.count(run.issues, &Issue.blocking?/1)
    by_rule = run.issues |> Enum.frequencies_by(& &1.rule) |> pairs()

    [
      "Findings: #{length(run.issues)} reported (#{by_rule}), #{blocking} gating and new\n",
      Enum.map(run.coverage_violations, &["Coverage violation: ", &1, "\n"]),
      Enum.map(run.completion_reasons, &["Note: ", &1, "\n"]),
      "Result: #{run.completion}, exit #{run.exit_code}\n"
    ]
  end
end
