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

  Options: `--output PATH` (default: the configured baseline), `--config`,
  `--profile`, `--rules`, `--except`, `--require-static-return`. Filters
  (`--module`, `--app`) are rejected: a baseline from a partial run would
  drop entries. Exit status 2 on errors or an incomplete run.
  """

  use Mix.Task

  alias SpecLint.{Baseline, CLI, Project, Run}
  alias Mix.Tasks.SpecLint, as: Task

  @impl true
  @spec run([String.t()]) :: :ok
  def run(argv) do
    cli = ok!(CLI.parse(argv))

    if cli.modules != [] or cli.apps != [] or cli.explain,
      do: Mix.raise("mix spec_lint.baseline analyses the whole project", exit_status: 2)

    Task.compile!()
    project = Project.current()
    config = Task.load_config!(project, cli)
    output = Path.expand(cli.output || config.baseline, project.root)
    run = ok!(Run.execute(project, config, only: cli.only, except: cli.except))

    cond do
      run.capabilities == nil ->
        Mix.raise("unsupported compiler: #{Enum.join(run.completion_reasons, "; ")}",
          exit_status: 2
        )

      run.completion != :complete ->
        Mix.raise("incomplete run: #{Enum.join(run.completion_reasons, "; ")}", exit_status: 2)

      true ->
        write(run, output)
    end
  end

  defp write(run, output) do
    previous =
      case Baseline.load(output) do
        {:ok, baseline} -> baseline
        _ -> nil
      end

    baseline = Baseline.build(run.issues, run.inventory, run.capabilities.adapter_id, previous)
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
