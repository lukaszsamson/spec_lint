defmodule SpecLint.GuardFeasibility do
  @moduledoc false

  # This is a bounded positive proof. A witness is accepted only after the
  # complete source head matches, at least one expanded guard evaluates true,
  # and every preceding clause provably rejects the same input. The search
  # keeps at most 4096 candidates after each Cartesian-product step.
  # Unsupported syntax and exhaustion mean unknown, never feasible.
  @samples [:a, :b, nil, false, true, 0, 1, -1, 0.0, "", [], [nil], {}, {:a}, %{}]
  @limit 4096
  @predicates [
    :is_atom,
    :is_integer,
    :is_float,
    :is_number,
    :is_binary,
    :is_bitstring,
    :is_boolean,
    :is_nil,
    :is_list,
    :is_tuple,
    :is_map,
    :is_pid,
    :is_port,
    :is_reference,
    :is_function,
    :is_map_key
  ]
  @comparisons [:"=:=", :"=/=", :==, :"/=", :<, :>, :"=<", :>=]
  @arithmetic [:+, :-, :*, :div, :rem]

  @spec proven?([tuple()]) :: boolean()
  def proven?(definitions), do: Enum.all?(definitions, &definition_proven?/1)

  defp definition_proven?({_fun_arity, _kind, _meta, clauses}) do
    Enum.reduce_while(clauses, [], &advance_clause/2) != :unproven
  end

  defp advance_clause(clause, previous) do
    if clause_proven?(clause, previous),
      do: {:cont, [clause | previous]},
      else: {:halt, :unproven}
  end

  defp clause_proven?({_meta, _patterns, [], _body}, _previous), do: true

  defp clause_proven?({_meta, patterns, guards, _body}, previous) do
    samples = samples(guards)

    if Enum.all?(patterns, &supported_pattern?/1) and
         Enum.all?(previous, fn {_meta, prior, _guards, _body} ->
           Enum.all?(prior, &supported_pattern?/1)
         end) do
      patterns
      |> Enum.map(&candidates(&1, samples))
      |> combinations()
      |> Enum.any?(&witness?(&1, patterns, guards, previous))
    else
      false
    end
  end

  defp clause_proven?(_, _), do: false

  defp witness?(args, patterns, guards, previous) do
    with {:ok, bindings} <- match_all(patterns, args, %{}),
         true <- Enum.any?(guards, &guard_true?(&1, bindings)),
         true <- Enum.all?(previous, &excludes?(&1, args)) do
      true
    else
      _ -> false
    end
  end

  defp excludes?({_meta, patterns, guards, _body}, args) do
    case match_all(patterns, args, %{}) do
      :error ->
        true

      {:ok, bindings} ->
        guards != [] and Enum.all?(guards, &(eval(&1, bindings) == {:ok, false}))
    end
  end

  defp supported_pattern?({:=, _, [left, right]}),
    do: supported_pattern?(left) and supported_pattern?(right)

  defp supported_pattern?({:{}, _, elements}), do: Enum.all?(elements, &supported_pattern?/1)

  defp supported_pattern?({:%, _, [module, {:%{}, _, _} = fields]}),
    do: variable?(module) and supported_pattern?(fields)

  defp supported_pattern?({:%{}, _, fields}),
    do: Enum.all?(fields, fn {key, value} -> is_atom(key) and supported_pattern?(value) end)

  defp supported_pattern?([]), do: true

  defp supported_pattern?([head | tail]),
    do: supported_pattern?(head) and supported_pattern?(tail)

  defp supported_pattern?({name, meta, context})
       when is_atom(name) and is_list(meta) and (is_atom(context) or is_nil(context)), do: true

  defp supported_pattern?(value)
       when is_atom(value) or is_number(value) or is_binary(value), do: true

  defp supported_pattern?(_), do: false

  defp variable?({name, meta, context})
       when is_atom(name) and is_list(meta) and (is_atom(context) or is_nil(context)),
       do: name != :_

  defp variable?(_), do: false

  defp samples(guards) do
    literals =
      Macro.prewalk(guards, [], fn
        value, acc when is_atom(value) or is_number(value) or is_binary(value) ->
          {value, [value | acc]}

        node, acc ->
          {node, acc}
      end)
      |> elem(1)

    Enum.uniq(literals ++ @samples ++ [fn -> :ok end, fn x -> x end, fn x, _ -> x end])
  end

  defp candidates({:=, _, [left, right]}, samples) do
    (candidates(left, samples) ++ candidates(right, samples)) |> Enum.uniq()
  end

  defp candidates({:{}, _, elements}, samples) do
    elements |> Enum.map(&candidates(&1, samples)) |> combinations() |> Enum.map(&List.to_tuple/1)
  end

  defp candidates({:%, _, [module, map]}, samples) do
    if variable?(module) do
      tags = Enum.filter(samples, &is_atom/1)

      [tags, candidates(map, samples)]
      |> combinations()
      |> Enum.map(fn [tag, fields] -> Map.put(fields, :__struct__, tag) end)
    else
      []
    end
  end

  defp candidates({:%{}, _, fields}, samples) do
    case Enum.map(fields, &field_candidates(&1, samples)) do
      [] -> [%{}]
      entries -> entries |> combinations() |> Enum.map(&Map.new/1)
    end
  end

  defp candidates([], _samples), do: [[]]

  defp candidates([head | tail], samples) do
    [candidates(head, samples), candidates(tail, samples)]
    |> combinations()
    |> Enum.map(fn [h, t] -> [h | t] end)
  end

  defp candidates({name, meta, context}, samples)
       when is_atom(name) and is_list(meta) and (is_atom(context) or is_nil(context)),
       do: samples

  defp candidates(value, _samples)
       when is_atom(value) or is_number(value) or is_binary(value), do: [value]

  defp candidates(_pattern, _samples), do: []

  defp field_candidates({key, value}, samples),
    do: Enum.map(candidates(value, samples), &{key, &1})

  defp combinations(parts) do
    Enum.reduce(parts, [[]], fn candidates, acc ->
      acc
      |> Stream.flat_map(&append_values(&1, candidates))
      |> Enum.take(@limit)
    end)
  end

  defp append_values(prefix, candidates),
    do: Stream.map(candidates, fn value -> prefix ++ [value] end)

  defp match_all([], [], bindings), do: {:ok, bindings}

  defp match_all([pattern | patterns], [value | values], bindings) do
    with {:ok, bindings} <- match(pattern, value, bindings),
         do: match_all(patterns, values, bindings)
  end

  defp match_all(_, _, _), do: :error

  defp match({:=, _, [left, right]}, value, bindings) do
    with {:ok, bindings} <- match(left, value, bindings), do: match(right, value, bindings)
  end

  defp match({:{}, _, elements}, value, bindings)
       when is_tuple(value) and tuple_size(value) == length(elements),
       do: match_all(elements, Tuple.to_list(value), bindings)

  defp match({:%, _, [module, {:%{}, _, _} = fields]}, value, bindings)
       when is_map(value) do
    with {:ok, tag} when is_atom(tag) <- Map.fetch(value, :__struct__),
         {:ok, bindings} <- match(module, tag, bindings) do
      match(fields, value, bindings)
    else
      _ -> :error
    end
  end

  defp match({:%{}, _, fields}, value, bindings) when is_map(value) do
    Enum.reduce_while(fields, {:ok, bindings}, fn {key, pattern}, {:ok, acc} ->
      case match_field(value, key, pattern, acc) do
        {:ok, next} -> {:cont, {:ok, next}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp match([], [], bindings), do: {:ok, bindings}

  defp match([head | tail], [value | values], bindings) do
    with {:ok, bindings} <- match(head, value, bindings), do: match(tail, values, bindings)
  end

  defp match({name, meta, context}, value, bindings)
       when is_atom(name) and is_list(meta) and (is_atom(context) or is_nil(context)) do
    if name == :_ do
      {:ok, bindings}
    else
      key = Keyword.get(meta, :version, {name, context})

      case Map.fetch(bindings, key) do
        {:ok, ^value} -> {:ok, bindings}
        {:ok, _} -> :error
        :error -> {:ok, Map.put(bindings, key, value)}
      end
    end
  end

  defp match(literal, value, bindings)
       when (is_atom(literal) or is_number(literal) or is_binary(literal)) and literal === value,
       do: {:ok, bindings}

  defp match(_, _, _), do: :error

  defp match_field(value, key, pattern, bindings) do
    with {:ok, field} <- Map.fetch(value, key), do: match(pattern, field, bindings)
  end

  defp guard_true?(guard, bindings), do: eval(guard, bindings) == {:ok, true}

  defp eval({name, meta, context}, bindings)
       when is_atom(name) and is_list(meta) and (is_atom(context) or is_nil(context)),
       do: Map.fetch(bindings, Keyword.get(meta, :version, {name, context}))

  defp eval({{:., _, [:erlang, :andalso]}, _, [left, right]}, bindings) do
    case eval(left, bindings) do
      {:ok, true} -> eval(right, bindings)
      {:ok, false} -> {:ok, false}
      _ -> :error
    end
  end

  defp eval({{:., _, [:erlang, :orelse]}, _, [left, right]}, bindings) do
    case eval(left, bindings) do
      {:ok, true} -> {:ok, true}
      {:ok, false} -> eval(right, bindings)
      _ -> :error
    end
  end

  defp eval({{:., _, [:erlang, :not]}, _, [arg]}, bindings) do
    case eval(arg, bindings) do
      {:ok, value} when is_boolean(value) -> {:ok, not value}
      _ -> :error
    end
  end

  defp eval({{:., _, [:erlang, fun]}, _, args}, bindings)
       when fun in @predicates or fun in @comparisons or fun in @arithmetic do
    with {:ok, values} <- eval_all(args, bindings),
         true <- :erlang.function_exported(:erlang, fun, length(values)) do
      try do
        {:ok, apply(:erlang, fun, values)}
      rescue
        _ -> :error
      catch
        _, _ -> :error
      end
    else
      _ -> :error
    end
  end

  defp eval(value, _bindings)
       when is_atom(value) or is_number(value) or is_binary(value), do: {:ok, value}

  defp eval([], _bindings), do: {:ok, []}

  defp eval([head | tail], bindings) do
    with {:ok, h} <- eval(head, bindings), {:ok, t} <- eval(tail, bindings), do: {:ok, [h | t]}
  end

  defp eval({:{}, _, elements}, bindings) do
    with {:ok, values} <- eval_all(elements, bindings), do: {:ok, List.to_tuple(values)}
  end

  defp eval(_, _), do: :error

  defp eval_all(expressions, bindings) do
    Enum.reduce_while(expressions, {:ok, []}, fn expression, {:ok, acc} ->
      case eval(expression, bindings) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      :error -> :error
    end
  end
end
