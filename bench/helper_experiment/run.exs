# Run with the pinned Elixir 1.21.0-dev c24c235 build. This script only reads
# the compiler's own stored signatures; it does not call SpecLint.
source = Path.join(__DIR__, "frozen_cases.ex")
output = Path.join(System.tmp_dir!(), "helper_experiment_#{System.unique_integer([:positive])}")
File.mkdir_p!(output)

try do
  {compile_us, {:ok, modules, diagnostics}} =
    :timer.tc(fn ->
      Kernel.ParallelCompiler.compile_to_path([source], output, return_diagnostics: true)
    end)

  for module <- modules do
    beam = Path.join(output, "#{module}.beam")

    {:ok, {^module, [{~c"ExCk", chunk}]}} =
      :beam_lib.chunks(String.to_charlist(beam), [~c"ExCk"])

    {version, %{exports: exports}} = :erlang.binary_to_term(chunk)

    IO.puts(
      "compiler=#{System.version()} checker=#{version} compile_us=#{compile_us} diagnostics=#{inspect(diagnostics)}"
    )

    for {{name, arity}, %{sig: {:infer, _, clauses}}} <- Enum.sort(exports) do
      IO.puts("#{name}/#{arity}")

      for {args, ret} <- clauses do
        IO.puts(
          "  (#{Enum.map_join(args, ", ", &Module.Types.Descr.to_quoted_string/1)}) -> " <>
            Module.Types.Descr.to_quoted_string(ret)
        )
      end
    end
  end
after
  File.rm_rf!(output)
end
