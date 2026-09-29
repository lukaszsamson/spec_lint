# Compiles the counterexample modules in this directory into a temporary
# directory, prints the inferred signature the compiler stores in each
# module's checker chunk (ExCk), runs the runtime witnesses, and raises if
# an observation differs from the one recorded in README.md.
#
#     elixir bench/corpus/compiler_counterexamples/check.exs
#
# It uses only the Elixir it runs on (Module.Types.Descr prints the stored
# types); nothing here calls SpecLint.

dir = __DIR__

out =
  Path.join(System.tmp_dir!(), "compiler_counterexamples_#{System.unique_integer([:positive])}")

File.mkdir_p!(out)

try do
  sources = dir |> Path.join("*.ex") |> Path.wildcard() |> Enum.sort()

  {:ok, modules, _diagnostics} =
    Kernel.ParallelCompiler.compile_to_path(sources, out, return_diagnostics: true)

  signatures =
    for module <- Enum.sort(modules),
        beam = Path.join(out, "#{module}.beam"),
        {:ok, {^module, [{~c"ExCk", chunk}]}} =
          :beam_lib.chunks(String.to_charlist(beam), [~c"ExCk"]),
        {_version, %{exports: exports}} = :erlang.binary_to_term(chunk),
        {{name, arity}, %{sig: {:infer, _domain, clauses}}} <- Enum.sort(exports),
        into: %{} do
      printed =
        for {args, return} <- clauses do
          "(" <>
            Enum.map_join(args, ", ", &Module.Types.Descr.to_quoted_string/1) <>
            ") -> " <>
            Module.Types.Descr.to_quoted_string(return)
        end

      {"#{inspect(module)}.#{name}/#{arity}", printed}
    end

  expected = %{
    "CompilerCounterexamples.HelperInsensitivity.sign/1" => [
      "(:nan) -> dynamic()",
      "(integer()) -> :negative or :positive or :zero"
    ],
    "CompilerCounterexamples.HelperInsensitivity.sign_inline/1" => [
      "(:nan) -> {:error, :nan}",
      "(integer()) -> :negative or :positive or :zero"
    ],
    "CompilerCounterexamples.EnumMapResult.tags/1" => [
      "(empty_list() or non_empty_list(term(), term())) -> dynamic()"
    ],
    "CompilerCounterexamples.EnumMapResult.tags_for/1" => [
      "(empty_list() or non_empty_list(term(), term())) -> dynamic(list({term(), :tag}))"
    ]
  }

  for {function, clauses} <- Enum.sort(signatures) do
    IO.puts(function)
    Enum.each(clauses, &IO.puts("  " <> &1))
  end

  unless signatures == expected do
    raise "a stored signature changed; update README.md: #{inspect(signatures)}"
  end

  # Runtime witnesses: in-spec inputs returning values outside the spec,
  # with in-spec controls that stay inside it.
  Code.prepend_path(out)
  sign = Function.capture(CompilerCounterexamples.HelperInsensitivity, :sign, 1)
  tags = Function.capture(CompilerCounterexamples.EnumMapResult, :tags, 1)
  tags_for = Function.capture(CompilerCounterexamples.EnumMapResult, :tags_for, 1)

  witnesses = [
    {"sign(:nan)", sign.(:nan), {:error, :nan}},
    {"sign(-1)", sign.(-1), :negative},
    {"tags([:a])", tags.([:a]), [{:a, :tag}]},
    {"tags([])", tags.([]), []},
    {"tags_for([:a])", tags_for.([:a]), [{:a, :tag}]}
  ]

  for {call, observed, expected_value} <- witnesses do
    IO.puts("#{call} = #{inspect(observed)}")
    unless observed == expected_value, do: raise("witness changed: #{call}")
  end
after
  File.rm_rf!(out)
end
