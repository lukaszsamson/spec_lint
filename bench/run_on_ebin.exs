# Runs the `mix spec_lint` pipeline (SpecLint.Run and the reporters) over
# explicit ebin directories, for projects SpecLint cannot be added to as a
# dependency (for example the pinned OSS corpora of EXPERIMENTS.md).
#
#     MIX_ENV=test mix run bench/run_on_ebin.exs -- \
#       --ebin DIR [--ebin DIR ...] [--code-path DIR ...] --root DIR \
#       [--write-baseline FILE] [mix spec_lint options: --ci --profile ...
#        --format console|json --output FILE --baseline FILE --module Mod
#        --rules ... --except ... --explain Mod.fun/arity]
#
# The app name of each ebin is the name of its parent directory. --root is
# the project root: output paths are relative to it and .spec_lint.exs is
# read from it. --code-path directories are prepended to the code path so
# remote types resolve. The script exits with the same status mix spec_lint
# would (--explain exits 0 unless the run is incomplete, 2). --write-baseline
# applies the checks of mix spec_lint.baseline: no --module, --app, --rules
# or --except, a supported compiler and a complete run, or exit 2.

defmodule SpecLint.RunOnEbin do
  @moduledoc false

  alias SpecLint.{Baseline, CLI, Config, Explain, Project, Run}
  alias SpecLint.Report.{Console, Json}

  def main(argv) do
    argv = Enum.reject(argv, &(&1 == "--"))

    {own, rest} = split(argv, [], [])

    ebins = own |> Keyword.get_values(:ebin) |> Enum.map(&Path.expand/1)
    root = own[:root] || File.cwd!()
    if ebins == [], do: fail("usage: --ebin DIR ... --root DIR [spec_lint options]")

    code_paths = own |> Keyword.get_values(:code_path) |> Enum.map(&Path.expand/1)
    Enum.each(code_paths ++ ebins, &Code.prepend_path/1)

    cli = ok!(CLI.parse(rest))

    project =
      ebins
      |> Enum.map(&{&1 |> Path.dirname() |> Path.basename() |> String.to_atom(), &1})
      |> Project.from_ebins(root)

    config = ok!(Config.load(project.root, cli.config))
    config = ok!(Config.merge_cli(config, CLI.config_overrides(cli)))
    modules = if cli.explain, do: [elem(cli.explain, 0)], else: cli.modules

    run =
      ok!(
        Run.execute(project, config,
          ci: cli.ci,
          modules: modules,
          apps: cli.apps,
          only: cli.only,
          except: cli.except
        )
      )

    cond do
      cli.explain ->
        IO.puts(ok!(Explain.render(run, cli.explain)))
        System.halt(if run.exit_code == 2, do: 2, else: 0)

      own[:write_baseline] ->
        write_baseline(run, cli, own[:write_baseline])

      cli.format == :json ->
        json = Json.encode(Json.envelope(run))
        if cli.output, do: ok!(Json.write_atomic(cli.output, json)), else: IO.write(json)

      true ->
        text = Console.render(run)
        if cli.output, do: ok!(Json.write_atomic(cli.output, text))
        IO.write(text)
    end

    System.halt(run.exit_code)
  end

  # The guards of mix spec_lint.baseline (lib/mix/tasks/spec_lint.baseline.ex).
  defp write_baseline(run, cli, path) do
    cond do
      cli.modules != [] or cli.apps != [] or cli.only != nil or cli.except != [] ->
        fail("--write-baseline analyses the whole project with the configured rules")

      run.capabilities == nil ->
        fail("unsupported compiler: #{Enum.join(run.completion_reasons, "; ")}")

      run.completion != :complete ->
        fail("incomplete run: #{Enum.join(run.completion_reasons, "; ")}")

      true ->
        previous =
          case Baseline.load(path) do
            {:ok, baseline} -> baseline
            :missing -> nil
            {:error, message} -> fail(message)
          end

        rules = Enum.map(run.rules, fn {rule, _severity} -> rule.id() end)

        baseline =
          Baseline.build(run.issues, run.inventory, run.capabilities.adapter_id, previous,
            rules: rules
          )

        ok!(Baseline.write(path, baseline))
        IO.puts("baseline: #{length(baseline["findings"])} findings -> #{path}")
    end
  end

  @own %{
    "--ebin" => :ebin,
    "--code-path" => :code_path,
    "--root" => :root,
    "--write-baseline" => :write_baseline
  }

  # This script's own options take a value; everything else is passed to
  # SpecLint.CLI.
  defp split([option, value | rest], own, other) when is_map_key(@own, option),
    do: split(rest, own ++ [{Map.fetch!(@own, option), value}], other)

  defp split([arg | rest], own, other), do: split(rest, own, other ++ [arg])
  defp split([], own, other), do: {own, other}

  defp ok!({:ok, value}), do: value
  defp ok!(:ok), do: :ok
  defp ok!({:error, message}), do: fail(message)

  defp fail(message) do
    IO.puts(:stderr, "error: #{message}")
    System.halt(2)
  end
end

SpecLint.RunOnEbin.main(System.argv())
