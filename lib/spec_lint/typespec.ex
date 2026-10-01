defmodule SpecLint.Typespec do
  @moduledoc """
  Translates typespec ASTs (as returned by `Code.Typespec`) into the
  compiler's own types (`Module.Types.Descr`).

  Every translation is `{descr, exact?}`. The lattice cannot express integer
  ranges, sized binaries, charlists as strings and a few other refinements;
  those are widened and flagged inexact. An inexact translation always
  over-approximates the spec, never under-approximates it, so a
  disjointness proven against the translation holds for the real spec.
  """

  import Module.Types.Descr,
    only: [
      atom: 0,
      atom: 1,
      binary: 0,
      boolean: 0,
      closed_map: 1,
      dynamic: 0,
      empty_list: 0,
      empty_map: 0,
      float: 0,
      fun: 0,
      integer: 0,
      list: 1,
      non_empty_list: 1,
      non_empty_list: 2,
      none: 0,
      open_map: 0,
      open_map: 1,
      pid: 0,
      port: 0,
      reference: 0,
      term: 0,
      tuple: 0,
      tuple: 1
    ]

  import SpecLint.Descr

  @depth 8

  @typedoc "A translated type: the descr and whether it is exact."
  @type translated :: {term(), boolean()}

  @doc """
  Translates one spec clause of `module`: `{:ok, args, return}` with one
  translation per argument and one for the return, or `:error` when the
  clause uses a construct with no sound translation (a constraint other
  than `when x: type`, an unknown built-in), with the construct as the
  reason. A named type that cannot be read is `term()`, inexact.
  """
  @spec spec(tuple(), module()) :: {:ok, [translated()], translated()} | {:error, term()}
  def spec(clause, module) do
    env = %{module: module, stack: []}

    case debound(clause) do
      {:type, _, :fun, [{:type, _, :product, args}, return]} ->
        {:ok, Enum.map(args, &translate(&1, env)), translate(return, env)}

      other ->
        {:error, {:spec, other}}
    end
  catch
    {:unsupported, reason} -> {:error, reason}
  end

  @doc "Translates one type AST in the context of `module`."
  @spec type(tuple(), module()) :: {:ok, translated()} | {:error, term()}
  def type(ast, module) do
    {:ok, translate(ast, %{module: module, stack: []})}
  catch
    {:unsupported, reason} -> {:error, reason}
  end

  defp translate(type, env, depth \\ @depth)

  defp translate(_type, _env, 0), do: {term(), false}
  defp translate({:ann_type, _, [_var, t]}, env, d), do: translate(t, env, d)
  defp translate({:paren_type, _, [t]}, env, d), do: translate(t, env, d)
  defp translate({:atom, _, a}, _env, _d), do: {atom([a]), true}
  defp translate({:integer, _, _}, _env, _d), do: {integer(), false}
  defp translate({:char, _, _}, _env, _d), do: {integer(), false}
  defp translate({:op, _, _, _}, _env, _d), do: {integer(), false}
  defp translate({:op, _, _, _, _}, _env, _d), do: {integer(), false}
  defp translate({:var, _, :_}, _env, _d), do: {term(), true}
  defp translate({:var, _, _}, _env, _d), do: {term(), false}

  defp translate({:remote_type, _, [{:atom, _, mod}, {:atom, _, name}, args]}, env, d),
    do: expand(mod, name, args, env, d)

  defp translate({:user_type, _, name, args}, env, d), do: expand(env.module, name, args, env, d)
  defp translate({:type, _, name, args}, env, d), do: builtin(name, args, env, d)
  defp translate(other, _env, _d), do: throw({:unsupported, other})

  defp builtin(:union, members, env, d) do
    Enum.reduce(members, {none(), true}, fn member, {acc, exact} ->
      {descr, member_exact} = translate(member, env, d)
      {union(acc, descr), exact and member_exact}
    end)
  end

  defp builtin(name, [], _env, _d) when name in [:term, :any], do: {term(), true}
  defp builtin(:dynamic, [], _env, _d), do: {dynamic(), true}
  defp builtin(name, [], _env, _d) when name in [:none, :no_return], do: {none(), true}
  defp builtin(name, [], _env, _d) when name in [:atom, :module, :node], do: {atom(), true}
  defp builtin(:boolean, [], _env, _d), do: {boolean(), true}
  defp builtin(:integer, [], _env, _d), do: {integer(), true}

  defp builtin(name, _args, _env, _d)
       when name in [:non_neg_integer, :pos_integer, :neg_integer, :range, :arity, :byte, :char],
       do: {integer(), false}

  defp builtin(:float, [], _env, _d), do: {float(), true}
  defp builtin(:number, [], _env, _d), do: {union(integer(), float()), true}
  defp builtin(:binary, [], _env, _d), do: {binary(), true}
  defp builtin(:bitstring, [], _env, _d), do: {bitstring(), true}
  defp builtin(:binary, [{:integer, _, 0}, {:integer, _, 8}], _env, _d), do: {binary(), true}
  defp builtin(:binary, [{:integer, _, 0}, {:integer, _, 1}], _env, _d), do: {bitstring(), true}

  defp builtin(:binary, [{:integer, _, m}, {:integer, _, n}], _env, _d)
       when rem(m, 8) == 0 and rem(n, 8) == 0,
       do: {binary(), false}

  defp builtin(:binary, [_, _], _env, _d), do: {bitstring(), false}
  defp builtin(:nonempty_binary, [], _env, _d), do: {binary(), false}
  defp builtin(:nonempty_bitstring, [], _env, _d), do: {bitstring(), false}
  defp builtin(:pid, [], _env, _d), do: {pid(), true}
  defp builtin(:port, [], _env, _d), do: {port(), true}
  defp builtin(:reference, [], _env, _d), do: {reference(), true}
  defp builtin(:identifier, [], _env, _d), do: {union(pid(), union(port(), reference())), true}
  defp builtin(nil, [], _env, _d), do: {empty_list(), true}
  defp builtin(:list, [], _env, _d), do: {list(term()), true}

  defp builtin(:list, [elem], env, d) do
    {descr, exact} = translate(elem, env, d)
    {list(descr), exact}
  end

  defp builtin(:nonempty_list, [], _env, _d), do: {non_empty_list(term()), true}

  defp builtin(:nonempty_list, [elem], env, d) do
    {descr, exact} = translate(elem, env, d)
    {non_empty_list(descr), exact}
  end

  defp builtin(:maybe_improper_list, [], _env, _d),
    do: {union(empty_list(), non_empty_list(term(), term())), true}

  defp builtin(:maybe_improper_list, [elem, tail], env, d) do
    {e, e_exact} = translate(elem, env, d)
    {t, t_exact} = translate(tail, env, d)
    {union(empty_list(), non_empty_list(e, union(t, empty_list()))), e_exact and t_exact}
  end

  defp builtin(:nonempty_maybe_improper_list, [], _env, _d),
    do: {non_empty_list(term(), term()), true}

  defp builtin(:nonempty_maybe_improper_list, [elem, tail], env, d) do
    {e, e_exact} = translate(elem, env, d)
    {t, t_exact} = translate(tail, env, d)
    {non_empty_list(e, union(t, empty_list())), e_exact and t_exact}
  end

  defp builtin(:nonempty_improper_list, [elem, tail], env, d) do
    {e, e_exact} = translate(elem, env, d)
    {t, t_exact} = translate(tail, env, d)
    {non_empty_list(e, t), e_exact and t_exact}
  end

  defp builtin(name, [], _env, _d) when name in [:string, :charlist],
    do: {list(integer()), false}

  defp builtin(name, [], _env, _d) when name in [:nonempty_string, :nonempty_charlist],
    do: {non_empty_list(integer()), false}

  # iolist() is recursive: elements widen to term(), the tail stays exact.
  defp builtin(:iolist, [], _env, _d), do: {iolist(), false}
  defp builtin(:iodata, [], _env, _d), do: {union(binary(), iolist()), false}
  defp builtin(:tuple, :any, _env, _d), do: {tuple(), true}

  defp builtin(:tuple, elems, env, d) when is_list(elems) do
    {descrs, exact} = translate_all(elems, env, d)
    {tuple(descrs), exact}
  end

  defp builtin(:mfa, [], _env, _d), do: {tuple([atom(), atom(), integer()]), false}
  defp builtin(:timeout, [], _env, _d), do: {union(integer(), atom([:infinity])), false}
  defp builtin(:map, :any, _env, _d), do: {open_map(), true}
  defp builtin(:map, [], _env, _d), do: {empty_map(), true}
  defp builtin(:map, assocs, env, d) when is_list(assocs), do: map(assocs, env, d)
  defp builtin(name, [], _env, _d) when name in [:fun, :function], do: {fun(), true}
  defp builtin(:fun, [{:type, _, :any}, _return], _env, _d), do: {fun(), false}

  # Function types are contravariant in their arguments: widening an
  # argument narrows the function type, so an inexact argument can only be
  # over-approximated by the top function of that arity.
  defp builtin(:fun, [{:type, _, :product, args}, return], env, d) do
    {arg_descrs, args_exact} = translate_all(args, env, d)
    {ret, ret_exact} = translate(return, env, d)

    if args_exact,
      do: fun_type(arg_descrs, ret, ret_exact),
      else: {fun_of_arity(length(args)), false}
  end

  # A record type is `#name{}` whether the record is a classic tuple-based
  # one or an OTP 29 native record (a distinct term type the lattice does
  # not have); the BEAM does not say which, so it is any term, inexact.
  defp builtin(:record, _name_and_fields, _env, _d), do: {term(), false}

  defp builtin(name, args, _env, _d), do: throw({:unsupported, {name, length(args)}})

  defp translate_all(types, env, d) do
    Enum.map_reduce(types, true, fn type, exact ->
      {descr, type_exact} = translate(type, env, d)
      {descr, exact and type_exact}
    end)
  end

  defp iolist, do: union(empty_list(), non_empty_list(term(), union(binary(), empty_list())))

  # Literal map types are closed. A non-literal key opens the map; every
  # literal field of an open map is made optional too, since the open
  # part may already cover it (Dialyzer's reading), and a required field
  # would under-approximate.
  defp map(assocs, env, d) do
    {fields, open?, exact} =
      Enum.reduce(assocs, {[], false, true}, fn
        {:type, _, kind, [{:atom, _, key}, value]}, {fields, open?, exact}
        when kind in [:map_field_exact, :map_field_assoc] ->
          {descr, value_exact} = translate(value, env, d)
          {[{key, descr, kind == :map_field_assoc} | fields], open?, exact and value_exact}

        {:type, _, kind, [_key, value]}, {fields, _open?, _exact}
        when kind in [:map_field_exact, :map_field_assoc] ->
          {_descr, _value_exact} = translate(value, env, d)
          {fields, true, false}

        other, _acc ->
          throw({:unsupported, other})
      end)

    fields = Enum.reverse(fields)

    if open? do
      {open_map(for {key, descr, _optional?} <- fields, do: {key, field(descr, true)}), exact}
    else
      {closed_map(for {key, descr, optional?} <- fields, do: {key, field(descr, optional?)}),
       exact}
    end
  end

  defp expand(mod, name, args, env, d) do
    key = {mod, name, length(args)}

    if key in env.stack do
      {term(), false}
    else
      case fetch_type(mod, name, length(args)) do
        {:ok, params, body} -> expand_body(params, body, args, key, env, d)
        # A type that cannot be read (an Erlang module without debug info,
        # a missing module) is any term: sound, but inexact.
        :error -> {term(), false}
      end
    end
  end

  # Argument ASTs are written in the caller's module: qualify bare user
  # types before switching the context to the callee.
  defp expand_body(params, body, args, {mod, _, _} = key, env, d) do
    args = Enum.map(args, &qualify(&1, env.module))

    subst =
      params
      |> Enum.zip(args)
      |> Map.new(fn {{:var, _, param}, arg} -> {param, arg} end)

    translate(substitute(body, subst), %{module: mod, stack: [key | env.stack]}, d - 1)
  end

  # Type definitions are read from the module's BEAM once per process.
  defp fetch_type(mod, name, arity) do
    types =
      case Process.get({__MODULE__, mod}) do
        nil ->
          types =
            case Code.Typespec.fetch_types(mod) do
              {:ok, types} -> types
              :error -> []
            end

          Process.put({__MODULE__, mod}, types)
          types

        types ->
          types
      end

    case Enum.find(types, fn {_kind, {n, _body, params}} ->
           n == name and length(params) == arity
         end) do
      {_kind, {^name, body, params}} -> {:ok, params, body}
      nil -> :error
    end
  end

  defp qualify({:user_type, l, n, args}, module),
    do:
      {:remote_type, l, [{:atom, l, module}, {:atom, l, n}, Enum.map(args, &qualify(&1, module))]}

  defp qualify({:type, l, n, args}, module) when is_list(args),
    do: {:type, l, n, Enum.map(args, &qualify(&1, module))}

  defp qualify({:remote_type, l, [m, n, args]}, module),
    do: {:remote_type, l, [m, n, Enum.map(args, &qualify(&1, module))]}

  defp qualify({:ann_type, l, [v, t]}, module), do: {:ann_type, l, [v, qualify(t, module)]}
  defp qualify(other, _module), do: other

  # `when x: type` constraints are substituted into the clause.
  defp debound({:type, l, :bounded_fun, [fun, constraints]}) do
    subst =
      Map.new(constraints, fn
        {:type, _, :constraint, [{:atom, _, :is_subtype}, [{:var, _, name}, t]]} -> {name, t}
        other -> throw({:unsupported, other})
      end)

    {:type, l, :fun, substitute(elem(fun, 3), subst)}
  end

  defp debound(spec), do: spec

  defp substitute({:var, _, name} = var, subst), do: Map.get(subst, name, var)

  defp substitute({:type, l, n, args}, subst) when is_list(args),
    do: {:type, l, n, Enum.map(args, &substitute(&1, subst))}

  defp substitute({:user_type, l, n, args}, subst),
    do: {:user_type, l, n, Enum.map(args, &substitute(&1, subst))}

  defp substitute({:remote_type, l, [m, n, args]}, subst),
    do: {:remote_type, l, [m, n, Enum.map(args, &substitute(&1, subst))]}

  defp substitute({:ann_type, l, [v, t]}, subst), do: {:ann_type, l, [v, substitute(t, subst)]}
  defp substitute(list, subst) when is_list(list), do: Enum.map(list, &substitute(&1, subst))
  defp substitute(other, _subst), do: other
end
