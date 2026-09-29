# Compiles bench/triage/near_top.ex into a temporary directory and prints
# the inferred clauses, top-only flag, class and components of each slice
# (EXPERIMENTS.md, Phase 0 "Open": SpecLintRepro.NearTop.pk!/1 and esc/1).
#
#     MIX_ENV=test mix run bench/triage/near_top.exs
alias SpecLint.{Analysis, Compiler, Evidence}

source = Path.join(__DIR__, "near_top.ex")
ebin = Path.join(System.tmp_dir!(), "spec_lint_near_top_#{System.unique_integer([:positive])}")
File.mkdir_p!(ebin)
{_, 0} = System.cmd(System.find_executable("elixirc"), ["-o", ebin, source])

try do
  r = Analysis.module(Path.join(ebin, "Elixir.SpecLintRepro.NearTop.beam"))

  for f <- r.functions, s <- f.slices do
    rel = s.relations
    c = Evidence.classify(rel)

    inferred =
      Enum.map_join(f.inferred, " ; ", fn {args, ret} ->
        Enum.map_join(args, ",", &Compiler.to_string/1) <> " -> " <> Compiler.to_string(ret)
      end)

    IO.puts("#{inspect(f.mfa)} inferred=#{inferred}")
    IO.puts("  top_only=#{rel.top_only?} class=#{c.class} reasons=#{inspect(c.reasons)}")

    components =
      Enum.map(
        c.components,
        &{&1.label, &1.present_in_contributing?, SpecLint.Compiler.to_string(&1.descr)}
      )

    IO.puts("  components=#{inspect(components)}")
  end
after
  File.rm_rf!(ebin)
end
