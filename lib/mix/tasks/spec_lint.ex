defmodule Mix.Tasks.SpecLint do
  @shortdoc "Checks @spec declarations against compiler-inferred signatures"

  @moduledoc """
  Compiles the project and checks every exported function's `@spec`
  against the signature the compiler inferred for it.

      mix spec_lint [--warnings-as-errors] [--format json] [--output FILE]
                    [--module Mod ...] [--config FILE]

  Errors are contradictions in the compiler's types (a return disjoint
  from the spec, a spec domain no clause accepts). Warnings are clauses
  and return values the spec does not declare; see `SpecLint` for the
  checks.

  ## Configuration

  `.spec_lint.exs` in the project root (or `--config FILE`) evaluates to a
  keyword list:

      [
        ignore: [
          MyApp.Generated,            # a whole module
          {MyApp.Legacy, :parse},     # a function, any arity
          {MyApp.Legacy, :parse, 2},  # one function
          ~r/^MyApp\\.Proto\\./        # a regex on "Module.function/arity"
        ],
        warnings_as_errors: false
      ]

  ## Exit status

  0 when there is no error (and no warning with `--warnings-as-errors`),
  1 otherwise.
  """

  use Mix.Task

  @switches [
    warnings_as_errors: :boolean,
    format: :string,
    output: :string,
    module: :keep,
    config: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _positional} = OptionParser.parse!(args, strict: @switches)
    Mix.Task.run("compile")
    config = read_config(opts[:config])

    %{findings: findings, specs: specs, skipped: skipped} =
      SpecLint.run(ebins(), ignore: config[:ignore] || [], modules: modules(opts))

    errors = Enum.count(findings, &(&1.severity == :error))
    warnings = length(findings) - errors
    write(if(opts[:format] == "json", do: json(findings), else: console(findings)), opts[:output])

    Mix.shell().info(
      "spec_lint: #{specs} spec clauses checked, #{errors} error(s), #{warnings} warning(s)" <>
        skipped_note(skipped)
    )

    warnings_as_errors? = opts[:warnings_as_errors] || config[:warnings_as_errors] || false
    if errors > 0 or (warnings_as_errors? and warnings > 0), do: exit({:shutdown, 1})
  end

  defp skipped_note([]), do: ""

  defp skipped_note(skipped) do
    ", #{length(skipped)} skipped (unsupported type, first: " <>
      Enum.map_join(Enum.take(skipped, 1), "", fn {m, f, a, reason} ->
        "#{inspect(m)}.#{f}/#{a} #{inspect(reason)}"
      end) <> ")"
  end

  defp modules(opts) do
    case Keyword.get_values(opts, :module) do
      [] -> nil
      names -> Enum.map(names, &Module.concat([&1]))
    end
  end

  defp write("", nil), do: :ok
  defp write(output, nil), do: Mix.shell().info(output)
  defp write(output, path), do: File.write!(path, output)

  # The default config file may be absent; an explicit one must exist.
  defp read_config(nil) do
    if File.exists?(".spec_lint.exs"), do: read_config(".spec_lint.exs"), else: []
  end

  defp read_config(path) do
    if File.exists?(path) do
      {config, _binding} = Code.eval_file(path)
      config
    else
      Mix.raise("spec_lint: config file #{path} does not exist")
    end
  end

  defp ebins do
    if Mix.Project.umbrella?() do
      for {app, _path} <- Mix.Project.apps_paths(),
          do: Path.join([Mix.Project.build_path(), "lib", Atom.to_string(app), "ebin"])
    else
      [Mix.Project.compile_path()]
    end
  end

  defp console(findings) do
    Enum.map_join(findings, "\n", fn finding ->
      location = Enum.join(Enum.reject([finding.file, finding.line], &is_nil/1), ":")

      [
        "#{location}: #{finding.severity}: #{SpecLint.mfa(finding)}: #{finding.message}"
        | Enum.map(
            finding.spec ++ Enum.map(finding.inferred, &("inferred: " <> &1)),
            &("    " <> &1)
          )
      ]
      |> Enum.join("\n")
    end)
  end

  defp json(findings) do
    findings
    |> Enum.map(&%{&1 | module: inspect(&1.module)})
    |> JSON.encode!()
  end
end
