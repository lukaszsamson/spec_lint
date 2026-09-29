defmodule SpecLint.ReachabilityContextTest do
  use ExUnit.Case, async: true

  import SpecLint.TestHelpers

  alias SpecLint.{Beam, Compiler, Config, Issue, Project, Run}

  @moduletag :tmp_dir

  @source """
  defmodule SpecLint.ReachabilityContextProbe do
    @spec f(:a | :b) :: :ok
    def f(:a) do
      x = helper()
      case x do
        :never -> :wrong
        _ -> :wrong
      end
    end
    def f(:b), do: :ok
    defp helper(), do: :ok

    @spec g(:a | :b) :: :ok
    def g(:a), do: :wrong
    def g(:b), do: :ok

    def unrelated(:a = x) when is_integer(x), do: :dead
    def unrelated(_), do: :ok
  end
  """

  test "local helpers inform diagnostics without unrelated functions blocking selected findings",
       %{tmp_dir: dir} do
    ebin = elixirc!(dir, @source)
    module = SpecLint.ReachabilityContextProbe
    {:ok, %Beam{debug_info: {:ok, info}}} = Beam.read(Path.join(ebin, "#{module}.beam"))

    assert {:ok, diagnostics} =
             Compiler.pattern_diagnostics(
               module,
               info.file,
               info.checker_attributes,
               info.definitions
             )

    assert {{:f, 1}, 6} in diagnostics
    assert {{:unrelated, 1}, 17} in diagnostics

    # This is the regression's failure mode: a checker invocation with just
    # f/1 cannot infer helper/0's return and misses the body pattern.
    selected = Enum.filter(info.definitions, &(elem(&1, 0) == {:f, 1}))

    assert {:ok, []} =
             Compiler.pattern_diagnostics(module, info.file, info.checker_attributes, selected)

    project = Project.from_ebins([{:probe, ebin}], dir)

    for clause_local? <- [false, true] do
      config = %Config{baseline: "none.json", clause_local_qualification: clause_local?}
      assert {:ok, run} = Run.execute(project, config, ci: true)
      assert run.completion == :complete
      assert run.reachability == %{{module, :f, 1} => {:ok, [6]}, {module, :g, 1} => {:ok, []}}

      assert [%Issue{gate: false} = blocked] = sl001(run, {module, :f, 1})
      assert Issue.blocked(blocked) == [:clause_reachable]
      assert blocked.data.pattern_diagnostic_lines == [6]

      assert [%Issue{gate: true} = eligible] = sl001(run, {module, :g, 1})
      assert Issue.blocked(eligible) == []
    end
  end

  defp sl001(run, mfa), do: Enum.filter(run.issues, &(&1.mfa == mfa and &1.rule == "SL001"))
end
