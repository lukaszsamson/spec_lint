defmodule Mix.Tasks.SpecLint.Baseline do
  @shortdoc "Writes the SpecLint baseline review artifact"

  @moduledoc """
  Runs SpecLint over the whole project and writes a baseline: every
  reported finding with its structural fingerprint, and the coverage
  inventory with an acknowledgement for each unsupported or unavailable
  slice (DESIGN.md section 9).

      mix spec_lint.baseline
      mix spec_lint.baseline --output .spec_lint_baseline.json

  The file is a review artifact: commit it after reviewing the entries,
  and fill in `reason`, `owner` and `expires` where useful. Values of
  entries that still match are kept when the baseline is regenerated.
  Ordinary `mix spec_lint` runs never modify it.

  The run reads the previous baseline from the output file, so lost
  analysis (a removed spec), coverage regressions and the entries kept from
  the previous file all come from the file being written; the output file
  may not exist yet.

  Options: `--output PATH` (default: the configured baseline), `--config`,
  `--profile`, `--require-static-return`, `--[no-]clause-local-qualification`.
  The last two change which findings gate, and a baseline records the gate
  state of each finding (`SpecLint.Baseline`, "Gate state"), so write the
  baseline under the configuration CI uses. Filters (`--module`, `--app`)
  and rule selection (`--rules`, `--except`) are rejected: a baseline from
  a partial run or a narrower rule set would drop entries. Findings of
  rules the configuration turns `:off` are kept from the previous baseline
  unchanged. An existing output file that is not a valid baseline is an
  error, never silently overwritten. Exit status 2 on errors or an
  incomplete run.
  """

  use Mix.Task

  alias Mix.Tasks.SpecLint, as: Task
  alias SpecLint.{Baseline, CLI, Project, Run}

  @impl true
  @spec run([String.t()]) :: :ok
  def run(argv) do
    cli = ok!(CLI.parse(argv))
    check_scope!(cli)

    Task.compile!()
    project = Project.current()
    config = Task.load_config!(project, cli)
    output = Path.expand(cli.output || config.baseline, project.root)
    previous = previous!(output)
    # One file for the run and for what is kept: the one being written.
    config = %{config | baseline: output, baseline_explicit: false}
    run = ok!(Run.execute(project, config))

    complete!(run)
    write(run, output, previous)
  end

  defp check_scope!(cli) do
    if cli.modules != [] or cli.apps != [] or cli.explain,
      do: Mix.raise("mix spec_lint.baseline analyses the whole project", exit_status: 2)

    if cli.only != nil or cli.except != [],
      do:
        Mix.raise(
          "mix spec_lint.baseline runs the configured rules; --rules and --except would " <>
            "drop the entries of the rules left out",
          exit_status: 2
        )
  end

  defp complete!(%{capabilities: nil} = run),
    do:
      Mix.raise("unsupported compiler: #{Enum.join(run.completion_reasons, "; ")}",
        exit_status: 2
      )

  defp complete!(%{completion: :complete}), do: :ok

  defp complete!(run),
    do: Mix.raise("incomplete run: #{Enum.join(run.completion_reasons, "; ")}", exit_status: 2)

  defp previous!(output) do
    case Baseline.load(output) do
      {:ok, baseline} -> baseline
      :missing -> nil
      {:error, message} -> Mix.raise(message, exit_status: 2)
    end
  end

  defp write(run, output, previous) do
    rules = Enum.map(run.rules, fn {rule, _severity} -> rule.id() end)

    baseline =
      Baseline.build(run.issues, run.inventory, run.capabilities.adapter_id, previous,
        rules: rules
      )

    :ok = written!(Baseline.write(output, baseline))

    acknowledged = Enum.count(baseline["inventory"], &Map.has_key?(&1, "acknowledged"))

    Mix.shell().info(
      "spec_lint.baseline: #{length(baseline["findings"])} finding(s), " <>
        "#{length(baseline["inventory"])} inventory entries " <>
        "(#{acknowledged} acknowledged unsupported or unavailable) -> " <>
        Project.relative(run.project, output)
    )
  end

  defp ok!({:ok, value}), do: value
  defp ok!({:error, message}), do: Mix.raise(message, exit_status: 2)

  defp written!(:ok), do: :ok
  defp written!({:error, message}), do: Mix.raise(message, exit_status: 2)
end
