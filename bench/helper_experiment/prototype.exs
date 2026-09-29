# Experimental source transformation for a deliberately narrow helper summary:
# one private clause, no guard, arity one, body exactly its argument or a tuple
# with that argument once and only literals elsewhere. It does not alter the
# installed compiler, ExCk format, or SpecLint adapter.
source_file =
  System.argv() |> List.first() |> then(&(&1 || Path.join(__DIR__, "frozen_cases.ex")))

source = File.read!(source_file)
quoted = Code.string_to_quoted!(source)

{:defmodule, module_meta, [module_name, [do: {:__block__, block_meta, forms}]]} = quoted

arg_name = fn
  {name, meta, context} when is_atom(name) and is_list(meta) and is_atom(context) -> name
  _ -> nil
end

summary = fn body, name ->
  cond do
    arg_name.(body) == name ->
      :identity

    is_tuple(body) and tuple_size(body) == 2 and not Macro.quoted_literal?(body) ->
      elements = Tuple.to_list(body)
      variable_count = Enum.count(elements, &(arg_name.(&1) == name))

      if variable_count == 1 and
           Enum.all?(elements, &(is_atom(&1) or is_integer(&1) or arg_name.(&1) == name)) do
        {:tuple, elements}
      else
        nil
      end

    true ->
      nil
  end
end

head_call = fn
  {:when, _, [call | _guards]} -> call
  call -> call
end

private_counts =
  for {:defp, _, [head, _body]} <- forms,
      {name, _, args} <- [head_call.(head)],
      is_list(args),
      reduce: %{} do
    counts -> Map.update(counts, {name, length(args)}, 1, &(&1 + 1))
  end

summaries =
  for {:defp, _, [{name, _, [arg]}, [do: body]]} <- forms,
      Map.get(private_counts, {name, 1}) == 1,
      variable = arg_name.(arg),
      variable != nil,
      descriptor = summary.(body, variable),
      descriptor != nil,
      into: %{} do
    {name, descriptor}
  end

rewrite = fn body ->
  {_ast, unsupported?} =
    Macro.prewalk(body, false, fn
      {kind, _, _} = node, _found when kind in [:quote, :&, :unquote, :unquote_splicing] ->
        {node, true}

      node, found ->
        {node, found}
    end)

  if unsupported? do
    body
  else
    Macro.postwalk(body, fn
      {name, _meta, [actual]} = call ->
        case Map.get(summaries, name) do
          :identity ->
            actual

          {:tuple, elements} ->
            elements
            |> Enum.map(fn el -> if arg_name.(el), do: actual, else: el end)
            |> List.to_tuple()

          nil ->
            call
        end

      other ->
        other
    end)
  end
end

transformed_forms =
  Enum.map(forms, fn
    {:def, meta, [head, [do: body]]} -> {:def, meta, [head, [do: rewrite.(body)]]}
    other -> other
  end)

transformed =
  {:defmodule, module_meta, [module_name, [do: {:__block__, block_meta, transformed_forms}]]}

output = Path.join(System.tmp_dir!(), "helper_prototype_#{System.unique_integer([:positive])}")
File.mkdir_p!(output)

try do
  file = Path.join(output, "transformed.ex")
  File.write!(file, Macro.to_string(transformed))

  {compile_us, {:ok, [module], diagnostics}} =
    :timer.tc(fn ->
      Kernel.ParallelCompiler.compile_to_path([file], output, return_diagnostics: true)
    end)

  beam = Path.join(output, "#{module}.beam")
  {:ok, {^module, [{~c"ExCk", chunk}]}} = :beam_lib.chunks(String.to_charlist(beam), [~c"ExCk"])
  {_version, %{exports: exports}} = :erlang.binary_to_term(chunk)

  signatures =
    Map.new(exports, fn {{name, _arity}, %{sig: {:infer, _, clauses}}} -> {name, clauses} end)

  if Path.basename(source_file) == "frozen_cases.ex" do
    for {helper, inline} <- [
          {:identity_helper, :identity_inline},
          {:tuple_helper, :tuple_inline},
          {:multi_helper, :multi_inline},
          {:repeated_helper, :repeated_inline}
        ] do
      unless Map.fetch!(signatures, helper) == Map.fetch!(signatures, inline) do
        raise "prototype did not match inline control: #{helper}"
      end
    end
  end

  if Path.basename(source_file) == "adversarial_cases.ex" and
       Map.keys(summaries) != [:identity] do
    raise "adversarial helpers unexpectedly summarized: #{inspect(summaries)}"
  end

  if Path.basename(source_file) == "adversarial_cases.ex" do
    Code.prepend_path(output)
    guarded = Function.capture(module, :guarded_public, 1)
    call_shaped = Function.capture(module, :call_shaped_public, 1)
    quoted = Function.capture(module, :quoted_public, 1)
    captured_public = Function.capture(module, :captured_public, 1)
    captured = captured_public.(:bad)

    unless guarded.(:bad) == :other and call_shaped.(:bad) == :other and
             Macro.to_string(quoted.(:bad)) == "identity(:bad)" and captured.() == :bad do
      raise "adversarial runtime behavior changed"
    end
  end

  IO.puts(
    "summaries=#{inspect(Map.keys(summaries))} compile_us=#{compile_us} " <>
      "compile_warnings=#{length(diagnostics.compile_warnings)} runtime_warnings=#{length(diagnostics.runtime_warnings)}"
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
after
  File.rm_rf!(output)
end
