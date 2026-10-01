defmodule Mix.Tasks.SpecLintTest do
  use ExUnit.Case

  @moduletag timeout: 300_000

  setup_all do
    root = Path.expand("../tmp/task_project", __DIR__)
    File.rm_rf!(root)
    File.mkdir_p!(Path.join(root, "lib"))

    File.write!(Path.join(root, "mix.exs"), """
    defmodule TaskProject.MixProject do
      use Mix.Project

      def project do
        [app: :task_project, version: "0.1.0", deps: [{:spec_lint, path: #{inspect(Path.expand("..", __DIR__))}, runtime: false}]]
      end
    end
    """)

    File.write!(Path.join(root, "lib/task_project.ex"), """
    defmodule TaskProject do
      @spec bad(integer()) :: atom()
      def bad(x), do: {:ok, x}

      @spec warn(atom()) :: {:ok, atom()}
      def warn(a), do: if(a == :no, do: :error, else: {:ok, a})
    end
    """)

    %{root: root}
  end

  defp spec_lint(root, args) do
    System.cmd("mix", ["spec_lint" | args],
      cd: root,
      stderr_to_stdout: true,
      env: [{"MIX_ENV", "dev"}]
    )
  end

  test "reports findings and exits 1 on errors, 0 once they are ignored", %{root: root} do
    {output, 1} = spec_lint(root, [])

    assert output =~
             "lib/task_project.ex:3: error: TaskProject.bad/1: inferred return {:ok, term()}"

    assert output =~
             "lib/task_project.ex:6: warning: TaskProject.warn/1: inferred return includes :error"

    assert output =~ "spec_lint: 2 spec clauses checked, 1 error(s), 1 warning(s)"

    File.write!(Path.join(root, ".spec_lint.exs"), "[ignore: [{TaskProject, :bad, 1}]]")
    {output, 0} = spec_lint(root, [])
    assert output =~ "1 warning(s)"
    refute output =~ "error:"

    {_output, 1} = spec_lint(root, ["--warnings-as-errors"])

    File.write!(Path.join(root, ".spec_lint.exs"), "[ignore: [TaskProject]]")
    {output, 0} = spec_lint(root, ["--format", "json", "--output", "out.json"])
    assert output =~ "0 error(s), 0 warning(s)"
    assert File.read!(Path.join(root, "out.json")) == "[]"
  end
end
