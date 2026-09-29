# Profiles the product pipeline on the pinned Absinthe build: the wall
# time of SpecLint.Run.execute/3 (`--ci`, no rendering), of rendering the
# JSON and console reports, and how many types each stage printed (VM-wide
# call counts of the adapter's printer and of Descr.to_quoted_string/2).
# The worker's stack is sampled every 500 ms.
#
#     MIX_ENV=test mix run bench/absinthe_profile.exs [--no-rules] [ABSINTHE_ROOT]
#
# ABSINTHE_ROOT defaults to /tmp/spec-lint-expansion/absinthe (the pinned,
# compiled checkout of bench/corpus/expansion.json). The run uses the
# default rules, as `mix spec_lint --ci` does. `--no-rules` selects no rule
# (`only: []`), which is what the Phase 4 profile measured
# (`reports/phase4/absinthe.profile.md`): analysis and classification still
# run, rules, reachability checks and SL008 do not.

alias SpecLint.{Config, Project, Run}
alias SpecLint.Report.{Console, Json}

{flags, args} = Enum.split_with(System.argv(), &String.starts_with?(&1, "--"))
only = if "--no-rules" in flags, do: [], else: nil
root = List.first(args) || "/tmp/spec-lint-expansion/absinthe"
for dir <- Path.wildcard(Path.join(root, "_build/test/lib/*/ebin")), do: Code.prepend_path(dir)
ebin = Path.join(root, "_build/test/lib/absinthe/ebin")

printers = [{SpecLint.Compiler.V121, :to_string, 1}, {Module.Types.Descr, :to_quoted_string, 2}]
# Call counting only applies to loaded modules.
Enum.each(printers, fn {module, _, _} -> Code.ensure_loaded!(module) end)

counted = fn fun ->
  Enum.each(printers, &:erlang.trace_pattern(&1, true, [:call_count]))
  {us, result} = :timer.tc(fun)

  counts =
    for mfa <- printers do
      {:call_count, count} = :erlang.trace_info(mfa, :call_count)
      count
    end

  Enum.each(printers, &:erlang.trace_pattern(&1, false, [:call_count]))
  {div(us, 1000), counts, result}
end

parent = self()

worker =
  spawn_link(fn ->
    project = Project.from_ebins([{:absinthe, ebin}], root)
    {:ok, config} = Config.load(project.root, nil)

    {ms, [adapter, descr], {:ok, run}} =
      counted.(fn ->
        Run.execute(project, config, ci: true, modules: [], apps: [], only: only, except: [])
      end)

    IO.puts("rules: #{if only == [], do: "none", else: "default"}")
    IO.puts("execute: #{ms} ms, printed #{adapter} types (#{descr} Descr prints)")
    IO.puts("findings: #{length(run.issues)}, exit code #{run.exit_code}, #{run.completion}")

    {ms, [adapter, descr], json} =
      counted.(fn -> run |> Json.envelope() |> Json.encode() |> IO.iodata_to_binary() end)

    IO.puts("json render: #{ms} ms, #{byte_size(json)} bytes, printed #{adapter} (#{descr})")

    {ms, [adapter, descr], console} =
      counted.(fn -> run |> Console.render() |> IO.iodata_to_binary() end)

    IO.puts(
      "console render: #{ms} ms, #{byte_size(console)} bytes, printed #{adapter} (#{descr})"
    )

    send(parent, :done)
  end)

samples = :ets.new(:samples, [:public])

spawn(fn ->
  Stream.repeatedly(fn ->
    Process.sleep(500)

    case :erlang.process_info(worker, :current_stacktrace) do
      {:current_stacktrace, st} when st != [] ->
        key =
          st
          |> Enum.take(7)
          |> Enum.map_join(" < ", fn {m, f, a, _} -> "#{inspect(m)}.#{f}/#{a}" end)

        :ets.update_counter(samples, key, {2, 1}, {key, 0})

      other ->
        :ets.update_counter(samples, inspect(other), {2, 1}, {inspect(other), 0})
    end
  end)
  |> Stream.run()
end)

receive do
  :done -> :ok
after
  1_500_000 -> IO.puts("TIMEOUT after 1500 s")
end

IO.puts("TOP STACK SAMPLES (500 ms interval)")

:ets.tab2list(samples)
|> Enum.sort_by(&(-elem(&1, 1)))
|> Enum.take(25)
|> Enum.each(fn {k, c} -> IO.puts("  #{c}  #{k}") end)
