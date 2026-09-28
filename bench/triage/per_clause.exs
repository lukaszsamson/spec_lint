# Per-clause probe of top-only slices (EXPERIMENTS.md, Phase 0 "Fixed after
# the report", the per-clause evidence question of DESIGN.md section 12):
# for each contributing clause of a top-only slice whose own return upper
# bound is not top, prints its extra against S_hi.
#
#     MIX_ENV=test mix run bench/triage/per_clause.exs -- $SPEC_LINT_OSS/ecto
#
# The argument is a compiled checkout (MIX_ENV=test); its app is the
# directory name. The probe found the 4 stale ecto specs of the Phase 0
# triage; they are the SL001-grade omissions reproduced in
# test/support/omission_fixtures.ex.
alias SpecLint.{Analysis, Compiler, TypeCache}

[checkout] = Enum.reject(System.argv(), &(&1 == "--"))
checkout = Path.expand(checkout)
app = Path.basename(checkout)
for d <- Path.wildcard(checkout <> "/_build/test/lib/*/ebin"), do: Code.prepend_path(d)
{:ok, caps} = Compiler.preflight()
cache = TypeCache.new()

for beam <- Enum.sort(Path.wildcard(checkout <> "/_build/test/lib/#{app}/ebin/*.beam")),
    m = Analysis.module(beam, cache: cache, preflight: {:ok, caps}),
    f <- m.functions,
    s <- f.slices,
    rel = s.relations,
    rel != nil and rel.top_only? do
  s_hi = s.return.hi

  rows =
    for c <- rel.contributing,
        up = Compiler.upper_bound(c.return),
        not Compiler.subtype?(Compiler.term(), up),
        not Compiler.empty?(up) do
      extra = Compiler.difference(up, s_hi)
      disjoint = Compiler.disjoint?(up, s_hi)
      {c.index, Compiler.empty?(extra), disjoint, Compiler.to_string(extra)}
    end

  bad = for {i, false, disj, ex} <- rows, do: {i, disj, ex}
  {mod, name, ar} = f.mfa

  if bad != [] do
    IO.puts(
      "#{inspect(mod)}.#{name}/#{ar} slice #{s.index} " <>
        "non-top clauses=#{length(rows)}/#{length(rel.contributing)}"
    )

    spec = s_hi |> Compiler.to_string() |> String.replace(~r/\s+/, " ") |> String.slice(0, 200)
    IO.puts("  spec return: #{spec}")

    for {i, disj, ex} <- bad do
      extra = ex |> String.replace(~r/\s+/, " ") |> String.slice(0, 200)
      IO.puts("  clause #{i} disjoint=#{disj} extra: #{extra}")
    end
  end
end
