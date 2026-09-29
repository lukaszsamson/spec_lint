alias SpecLint.{Project, Config, Run}
root = "/tmp/spec-lint-expansion/absinthe"
for dir <- Path.wildcard(Path.join(root, "_build/test/lib/*/ebin")), do: Code.prepend_path(dir)
ebin = Path.join(root, "_build/test/lib/absinthe/ebin")
parent = self()
worker = spawn_link(fn ->
  project = Project.from_ebins([{:absinthe, ebin}], root)
  {:ok, config} = Config.load(project.root, nil)
  t0 = System.monotonic_time(:millisecond)
  res = Run.execute(project, config, ci: true, modules: [], apps: [], only: [], except: [])
  t1 = System.monotonic_time(:millisecond)
  IO.puts("execute: #{t1 - t0} ms")
  {:ok, run} = res
  json = []; us = 0
  IO.puts("json render: #{div(us, 1000)} ms, #{IO.iodata_length(json)} bytes")
  us2 = 0
  IO.puts("console render: #{div(us2, 1000)} ms")
  send(parent, :done)
end)
samples = :ets.new(:samples, [:public])
spawn(fn ->
  Stream.repeatedly(fn ->
    Process.sleep(500)
    case :erlang.process_info(worker, :current_stacktrace) do
      {:current_stacktrace, st} when st != [] ->
        key = st |> Enum.take(7) |> Enum.map(fn {m, f, a, _} -> "#{inspect(m)}.#{f}/#{a}" end) |> Enum.join(" < ")
        :ets.update_counter(samples, key, {2, 1}, {key, 0})
      other -> :ets.update_counter(samples, inspect(other), {2, 1}, {inspect(other), 0})
    end
    if rem(System.os_time(:second), 60) == 0 do
      IO.puts("--- sample dump @#{System.os_time(:second)}")
      :ets.tab2list(samples) |> Enum.sort_by(&(-elem(&1, 1))) |> Enum.take(8) |> Enum.each(fn {k, c} -> IO.puts("  #{c}  #{k}") end)
    end
  end) |> Stream.run()
end)
receive do
  :done -> :ok
after 1_500_000 -> IO.puts("TIMEOUT after 1500 s")
end
IO.puts("TOP STACK SAMPLES (500 ms interval)")
:ets.tab2list(samples) |> Enum.sort_by(&(-elem(&1, 1))) |> Enum.take(25) |> Enum.each(fn {k, c} -> IO.puts("  #{c}  #{k}") end)
