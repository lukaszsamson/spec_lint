defmodule SpecLint.Translate do
  @moduledoc """
  Translates Erlang typespec ASTs (as returned by `Code.Typespec`) into
  `SpecLint.Bound` values over the compiler's type lattice.

  Audited successor of the prototype's `SpecToDescr` (DESIGN.md section 6).
  Every node yields `lo ⊆ S ⊆ hi` plus loss records:

    * Covariant constructors (unions, tuples, lists, map values, function
      returns) combine child bounds pointwise.
    * Function types are contravariant in their arguments, so an argument
      that translates inexactly cannot be widened: the arrow becomes
      `hi = fun(arity)`, `lo = none()` with `:arrow_polarity`.
    * Recursive types are cut off at a depth budget or on re-entry, with
      `hi = term()`, `lo = none()` and `:recursive_cutoff`.
    * `@opaque` and `@nominal` types of other modules are boundaries
      (`term()`/`none()`) unless `expand_opaque: true`.
    * A type variable that occurs in the return and anywhere else is
      substituted by its bound and the return keeps only its upper bound
      (`:type_variable_correlation`). Variables repeated only among the
      arguments are exact: each argument ranges over the bound independently.
    * Erlang records become open tuples tagged by the record name with
      `:record_fields_unknown`.
    * A construct with no sound translation makes the whole slice
      `{:unsupported, reason}`; other slices of the same spec still translate.

  Kept from the prototype: argument ASTs of a parameterised named type are
  qualified in the caller's module before substitution, and `iolist()`
  over-approximates improper lists instead of dropping them.
  """

  alias SpecLint.{Bound, Compiler, TypeCache}

  @default_depth 8

  @typedoc "Translation context."
  @type context :: %{
          root: module(),
          module: module(),
          cache: TypeCache.t(),
          stack: [{module(), atom(), arity()}],
          depth: non_neg_integer(),
          expand_opaque: boolean()
        }

  @typedoc "A translated spec clause."
  @type slice :: %{args: [Bound.t()], return: Bound.t()}

  @doc """
  Builds a translation context for specs of `module`.

  Options: `:expand_opaque` (default `false`), `:depth` (default #{@default_depth}).
  """
  @spec context(module(), TypeCache.t(), keyword()) :: context()
  def context(module, %TypeCache{} = cache, opts \\ []) do
    %{
      root: module,
      module: module,
      cache: cache,
      stack: [],
      depth: Keyword.get(opts, :depth, @default_depth),
      expand_opaque: Keyword.get(opts, :expand_opaque, false)
    }
  end

  @doc "Translates one spec clause (one slice)."
  @spec slice(tuple(), context()) :: {:ok, slice()} | {:unsupported, term()}
  def slice(clause_ast, context) do
    {fun_ast, constraints} = debound(clause_ast)

    case fun_ast do
      {:type, _, :fun, [{:type, _, :product, args}, return]} ->
        correlated = correlated_vars(args, return)
        subst = constraint_substitution(constraints)
        args = Enum.map(args, &substitute_all(&1, subst))
        return = substitute_all(return, subst)

        arg_bounds =
          args
          |> Enum.with_index()
          |> Enum.map(fn {arg, index} -> node(arg, context, [{:arg, index}]) end)

        return_bound = node(return, context, [:return])

        return_bound =
          if correlated == [] do
            return_bound
          else
            %{return_bound | lo: Compiler.none()}
            |> Bound.add_loss(:type_variable_correlation, [:return])
          end

        {:ok, %{args: arg_bounds, return: return_bound}}

      other ->
        throw({:unsupported, {:spec_shape, strip(other)}})
    end
  catch
    {:unsupported, reason} -> {:unsupported, reason}
  end

  @doc """
  Translates a single type AST in `context`. `path` prefixes loss paths.
  """
  @spec type(tuple(), context(), [Bound.segment()]) :: {:ok, Bound.t()} | {:unsupported, term()}
  def type(ast, context, path \\ []) do
    {:ok, node(ast, context, path)}
  catch
    {:unsupported, reason} -> {:unsupported, reason}
  end

  ## Spec clause helpers

  defp debound({:type, _, :bounded_fun, [fun, constraints]}), do: {fun, constraints}
  defp debound(fun), do: {fun, []}

  defp constraint_substitution(constraints) do
    Map.new(constraints, fn
      {:type, _, :constraint, [{:atom, _, :is_subtype}, [{:var, _, name}, type]]} ->
        {name, type}

      other ->
        throw({:unsupported, {:constraint, strip(other)}})
    end)
  end

  # Constraints may refer to other constrained variables; substitute until no
  # constrained variable is left. Recursive constraints such as
  # `deep_list: [any() | deep_list]` are cut off after the budget: remaining
  # occurrences become a cutoff marker translated as a recursive cutoff.
  defp substitute_all(ast, subst), do: substitute_all(ast, subst, map_size(subst) + 1)

  defp substitute_all(ast, subst, 0) do
    cutoff = Map.new(subst, fn {name, _type} -> {name, {:spec_lint_cutoff, name}} end)
    substitute(ast, cutoff)
  end

  defp substitute_all(ast, subst, budget) do
    next = substitute(ast, subst)
    if next == ast, do: ast, else: substitute_all(next, subst, budget - 1)
  end

  # Variables that occur in the return and at least one more time anywhere in
  # the clause (the return may be restricted per call).
  defp correlated_vars(args, return) do
    in_return = vars(return)
    counts = Enum.frequencies(Enum.flat_map(args, &vars/1) ++ in_return)

    in_return
    |> Enum.uniq()
    |> Enum.filter(&(Map.fetch!(counts, &1) >= 2))
  end

  defp vars({:var, _, :_}), do: []
  defp vars({:var, _, name}), do: [name]
  defp vars({:ann_type, _, [_var, type]}), do: vars(type)
  defp vars({:type, _, _, args}) when is_list(args), do: Enum.flat_map(args, &vars/1)
  defp vars({:user_type, _, _, args}), do: Enum.flat_map(args, &vars/1)
  defp vars({:remote_type, _, [_, _, args]}), do: Enum.flat_map(args, &vars/1)
  defp vars(list) when is_list(list), do: Enum.flat_map(list, &vars/1)
  defp vars(_other), do: []

  defp substitute({:var, _, name} = var, subst), do: Map.get(subst, name, var)

  defp substitute({:type, line, name, args}, subst) when is_list(args),
    do: {:type, line, name, Enum.map(args, &substitute(&1, subst))}

  defp substitute({:user_type, line, name, args}, subst),
    do: {:user_type, line, name, Enum.map(args, &substitute(&1, subst))}

  defp substitute({:remote_type, line, [mod, name, args]}, subst),
    do: {:remote_type, line, [mod, name, Enum.map(args, &substitute(&1, subst))]}

  defp substitute({:ann_type, line, [var, type]}, subst),
    do: {:ann_type, line, [var, substitute(type, subst)]}

  defp substitute(list, subst) when is_list(list), do: Enum.map(list, &substitute(&1, subst))
  defp substitute(other, _subst), do: other

  ## Nodes

  defp node({:ann_type, _, [_var, type]}, ctx, path), do: node(type, ctx, path)
  defp node({:paren_type, _, [type]}, ctx, path), do: node(type, ctx, path)
  defp node({:atom, _, atom}, _ctx, _path) when is_atom(atom), do: exact(Compiler.atom([atom]))
  defp node({:integer, _, _}, _ctx, path), do: refined_integer(path)
  defp node({:char, _, _}, _ctx, path), do: refined_integer(path)
  defp node({:op, _, _, _}, _ctx, path), do: refined_integer(path)
  defp node({:op, _, _, _, _}, _ctx, path), do: refined_integer(path)

  defp node({:spec_lint_cutoff, _name}, _ctx, path),
    do: Bound.upper(Compiler.term(), :recursive_cutoff, path)

  # Type variables left after `when` substitution and parameter substitution
  # are unconstrained: any term.
  defp node({:var, _, _}, _ctx, _path), do: exact(Compiler.term())

  defp node({:remote_type, _, [{:atom, _, mod}, {:atom, _, name}, args]}, ctx, path),
    do: named(mod, name, args, ctx, path)

  defp node({:user_type, _, name, args}, ctx, path), do: named(ctx.module, name, args, ctx, path)
  defp node({:type, _, name, args}, ctx, path), do: builtin(name, args, ctx, path)
  defp node(other, _ctx, _path), do: throw({:unsupported, {:construct, strip(other)}})

  defp exact(descr), do: Bound.exact(descr)

  defp refined_integer(path),
    do: Bound.upper(Compiler.integer(), :integer_refinement_erased, path)

  ## Builtin types

  defp builtin(:union, members, ctx, path) do
    members
    |> Enum.with_index()
    |> Enum.map(fn {member, index} -> node(member, ctx, path ++ [{:union, index}]) end)
    |> Bound.map_covariant(&Compiler.union_all/1)
  end

  defp builtin(name, [], _ctx, _path) when name in [:term, :any, :dynamic],
    do: exact(Compiler.term())

  defp builtin(name, [], _ctx, _path) when name in [:none, :no_return],
    do: exact(Compiler.none())

  defp builtin(name, [], _ctx, _path) when name in [:atom, :module, :node],
    do: exact(Compiler.atom())

  defp builtin(:boolean, [], _ctx, _path), do: exact(Compiler.boolean())
  defp builtin(:integer, [], _ctx, _path), do: exact(Compiler.integer())

  defp builtin(name, [], _ctx, path)
       when name in [:non_neg_integer, :pos_integer, :neg_integer, :arity, :byte, :char],
       do: refined_integer(path)

  defp builtin(:range, [_, _], _ctx, path), do: refined_integer(path)
  defp builtin(:float, [], _ctx, _path), do: exact(Compiler.float())

  defp builtin(:number, [], _ctx, _path),
    do: exact(Compiler.union(Compiler.integer(), Compiler.float()))

  defp builtin(:binary, [], _ctx, _path), do: exact(Compiler.binary())
  defp builtin(:bitstring, [], _ctx, _path), do: exact(Compiler.bitstring())
  defp builtin(:binary, [{:integer, _, m}, {:integer, _, n}], _ctx, path), do: sized(m, n, path)

  defp builtin(:nonempty_binary, [], _ctx, path),
    do: Bound.upper(Compiler.binary(), :sized_binary_erased, path)

  defp builtin(:nonempty_bitstring, [], _ctx, path),
    do: Bound.upper(Compiler.bitstring(), :sized_binary_erased, path)

  defp builtin(:pid, [], _ctx, _path), do: exact(Compiler.pid())
  defp builtin(:port, [], _ctx, _path), do: exact(Compiler.port())
  defp builtin(:reference, [], _ctx, _path), do: exact(Compiler.reference())

  defp builtin(:identifier, [], _ctx, _path),
    do: exact(Compiler.union_all([Compiler.pid(), Compiler.port(), Compiler.reference()]))

  defp builtin(nil, [], _ctx, _path), do: exact(Compiler.empty_list())
  defp builtin(:list, [], _ctx, _path), do: exact(Compiler.list(Compiler.term()))

  defp builtin(:list, [elem], ctx, path) do
    [node(elem, ctx, path ++ [:list_elem])]
    |> Bound.map_covariant(fn [e] -> Compiler.list(e) end)
  end

  defp builtin(:nonempty_list, [], _ctx, _path),
    do: exact(Compiler.non_empty_list(Compiler.term(), Compiler.empty_list()))

  defp builtin(:nonempty_list, [elem], ctx, path) do
    [node(elem, ctx, path ++ [:list_elem])]
    |> Bound.map_covariant(fn [e] -> Compiler.non_empty_list(e, Compiler.empty_list()) end)
  end

  defp builtin(:maybe_improper_list, [], _ctx, _path),
    do: exact(maybe_improper(Compiler.term(), Compiler.term()))

  defp builtin(:maybe_improper_list, [elem, tail], ctx, path) do
    list_with_tail(elem, tail, ctx, path, &maybe_improper/2)
  end

  defp builtin(:nonempty_maybe_improper_list, [], _ctx, _path),
    do: exact(Compiler.non_empty_list(Compiler.term(), Compiler.term()))

  defp builtin(:nonempty_maybe_improper_list, [elem, tail], ctx, path) do
    list_with_tail(elem, tail, ctx, path, fn e, t ->
      Compiler.non_empty_list(e, Compiler.union(t, Compiler.empty_list()))
    end)
  end

  defp builtin(:nonempty_improper_list, [elem, tail], ctx, path) do
    list_with_tail(elem, tail, ctx, path, &Compiler.non_empty_list/2)
  end

  # string() is [char()]: the element refinement is erased, [] is exact.
  defp builtin(:string, [], _ctx, path) do
    %Bound{
      lo: Compiler.empty_list(),
      hi: Compiler.list(Compiler.integer()),
      losses: [Bound.loss(:charlist_as_integers, path)]
    }
  end

  defp builtin(:nonempty_string, [], _ctx, path) do
    Bound.upper(
      Compiler.non_empty_list(Compiler.integer(), Compiler.empty_list()),
      :charlist_as_integers,
      path
    )
  end

  # iolist() is maybe_improper_list(byte() | binary() | iolist(), binary() | []).
  # The recursion is cut off: elements widen to term(), the terminator stays
  # exact, so improper iolists such as [?a | "bc"] are included.
  defp builtin(:iolist, [], _ctx, path) do
    %Bound{
      lo: Compiler.empty_list(),
      hi: iolist_over(),
      losses: [Bound.loss(:recursive_cutoff, path)]
    }
  end

  defp builtin(:iodata, [], _ctx, path) do
    %Bound{
      lo: Compiler.union(Compiler.binary(), Compiler.empty_list()),
      hi: Compiler.union(Compiler.binary(), iolist_over()),
      losses: [Bound.loss(:recursive_cutoff, path)]
    }
  end

  defp builtin(:tuple, :any, _ctx, _path), do: exact(Compiler.tuple())

  defp builtin(:tuple, elems, ctx, path) when is_list(elems) do
    elems
    |> Enum.with_index()
    |> Enum.map(fn {elem, index} -> node(elem, ctx, path ++ [{:elem, index}]) end)
    |> Bound.map_covariant(&Compiler.tuple/1)
  end

  defp builtin(:mfa, [], ctx, path) do
    builtin(
      :tuple,
      [{:type, 0, :atom, []}, {:type, 0, :atom, []}, {:type, 0, :arity, []}],
      ctx,
      path
    )
  end

  defp builtin(:timeout, [], _ctx, path) do
    %Bound{
      lo: Compiler.atom([:infinity]),
      hi: Compiler.union(Compiler.integer(), Compiler.atom([:infinity])),
      losses: [Bound.loss(:integer_refinement_erased, path ++ [{:union, 1}])]
    }
  end

  defp builtin(:map, :any, _ctx, _path), do: exact(Compiler.open_map())
  defp builtin(:map, [], _ctx, _path), do: exact(Compiler.empty_map())
  defp builtin(:map, assocs, ctx, path) when is_list(assocs), do: map(assocs, ctx, path)

  defp builtin(:fun, [], _ctx, _path), do: exact(Compiler.fun())
  defp builtin(:function, [], _ctx, _path), do: exact(Compiler.fun())

  defp builtin(:fun, [{:type, _, :any}, _return], _ctx, path),
    do: Bound.upper(Compiler.fun(), :arrow_polarity, path)

  defp builtin(:fun, [{:type, _, :product, args}, return], ctx, path),
    do: arrow(args, return, ctx, path)

  defp builtin(:record, [{:atom, _, name} | _fields], _ctx, path),
    do: Bound.upper(Compiler.open_tuple([Compiler.atom([name])]), :record_fields_unknown, path)

  defp builtin(name, args, _ctx, _path),
    do: throw({:unsupported, {:builtin, name, strip(args)}})

  defp maybe_improper(elem, tail) do
    Compiler.union(
      Compiler.empty_list(),
      Compiler.non_empty_list(elem, Compiler.union(tail, Compiler.empty_list()))
    )
  end

  defp list_with_tail(elem, tail, ctx, path, build) do
    [node(elem, ctx, path ++ [:list_elem]), node(tail, ctx, path ++ [:list_tail])]
    |> Bound.map_covariant(fn [e, t] -> build.(e, t) end)
  end

  defp iolist_over do
    Compiler.union(
      Compiler.empty_list(),
      Compiler.non_empty_list(
        Compiler.term(),
        Compiler.union(Compiler.binary(), Compiler.empty_list())
      )
    )
  end

  # <<_:M, _:_*N>>
  defp sized(0, 8, _path), do: exact(Compiler.binary())
  defp sized(0, 1, _path), do: exact(Compiler.bitstring())

  defp sized(m, n, path) do
    hi =
      if rem(m, 8) == 0 and rem(n, 8) == 0, do: Compiler.binary(), else: Compiler.bitstring()

    Bound.upper(hi, :sized_binary_erased, path)
  end

  ## Arrows

  defp arrow(args, return, ctx, path) do
    arg_bounds =
      args
      |> Enum.with_index()
      |> Enum.map(fn {arg, index} -> node(arg, ctx, path ++ [{:fun_arg, index}]) end)

    return_bound = node(return, ctx, path ++ [:fun_return])

    if Enum.all?(arg_bounds, &Bound.exact?/1) do
      arg_types = Enum.map(arg_bounds, & &1.hi)

      %Bound{
        lo: Compiler.fun(arg_types, return_bound.lo),
        hi: Compiler.fun(arg_types, return_bound.hi),
        losses: return_bound.losses,
        notes: Enum.flat_map(arg_bounds, & &1.notes) ++ return_bound.notes
      }
    else
      # Widening an argument narrows a function type (contravariance), so the
      # only sound upper bound is the top function of this arity.
      Bound.upper(Compiler.fun(length(args)), :arrow_polarity, path)
    end
  end

  ## Maps

  # Literal map types are closed. Literal atom keys become fields and take
  # precedence over key domains on overlap (the singleton-key reading of
  # Erlang map types). A non-literal key is exact only when it is an exact,
  # optional key that is either a finite atom set (expanded to optional
  # fields) or a union of whole base kinds not shared with another
  # non-literal association; anything else is widened with `:map_key_widened`.
  defp map(assocs, ctx, path) do
    entries =
      assocs
      |> Enum.with_index()
      |> Enum.map(fn {assoc, index} -> map_entry(assoc, index, ctx, path) end)

    {literals, losses} =
      entries
      |> Enum.filter(&(elem(&1, 0) == :literal))
      |> dedupe_literals(path)

    literal_keys = Enum.map(literals, fn {key, _bound, _optional?} -> key end)
    domains = Enum.filter(entries, &(elem(&1, 0) == :domain))
    shared = shared_kinds(domains)

    acc = %{fields: literals, domains: [], losses: losses, lo_empty?: false}

    acc =
      Enum.reduce(domains, acc, fn entry, acc ->
        add_domain(entry, literal_keys, shared, path, acc)
      end)

    build_map(acc)
  end

  defp map_entry({:type, _, kind, [key, value]}, index, ctx, path)
       when kind in [:map_field_exact, :map_field_assoc] do
    required? = kind == :map_field_exact

    case key do
      {:atom, _, atom} ->
        {:literal, atom, node(value, ctx, path ++ [{:map_value, atom}]), not required?}

      _ ->
        key_bound = node(key, ctx, path ++ [{:map_key, index}])
        value_bound = node(value, ctx, path ++ [{:map_value, index}])
        {:domain, key_bound, value_bound, required?, path ++ [{:map_key, index}]}
    end
  end

  defp map_entry(other, _index, _ctx, _path),
    do: throw({:unsupported, {:map_association, strip(other)}})

  # A literal key given twice keeps one field with the union of the values
  # (upper bound only).
  defp dedupe_literals(literals, path) do
    {fields, losses} =
      Enum.reduce(literals, {[], []}, fn {:literal, key, bound, optional?}, {fields, losses} ->
        case List.keyfind(fields, key, 0) do
          nil ->
            {fields ++ [{key, bound, optional?}], losses}

          {^key, previous, previous_optional?} ->
            union = Bound.map_covariant([previous, bound], &Compiler.union_all/1)
            field = {key, %{union | lo: Compiler.none()}, optional? and previous_optional?}
            loss = Bound.loss(:map_key_widened, path ++ [{:map_value, key}])
            {List.keyreplace(fields, key, 0, field), losses ++ [loss]}
        end
      end)

    {fields, losses}
  end

  defp shared_kinds(domains) do
    domains
    |> Enum.flat_map(fn {:domain, key, _value, _required?, _path} ->
      Compiler.key_kinds(key.hi)
    end)
    |> Enum.frequencies()
    |> Enum.filter(fn {_kind, count} -> count > 1 end)
    |> Enum.map(fn {kind, _count} -> kind end)
  end

  defp add_domain({:domain, key, value, required?, loss_path}, literal_keys, shared, _path, acc) do
    acc = %{acc | losses: acc.losses ++ key.losses}

    case finite_atoms(key) do
      {:ok, [atom]} when required? ->
        if atom in literal_keys do
          widened(acc, loss_path)
        else
          %{acc | fields: acc.fields ++ [{atom, value, false}]}
        end

      {:ok, atoms} ->
        new_fields = for atom <- atoms, atom not in literal_keys, do: {atom, value, true}
        acc = %{acc | fields: acc.fields ++ new_fields}
        if required?, do: widened(acc, loss_path), else: acc

      :error ->
        kinds = Compiler.key_kinds(key.hi)
        whole = Compiler.union_all(Enum.map(kinds, &Compiler.key_kind_descr/1))

        exact? =
          Bound.exact?(key) and not required? and Compiler.equal?(key.hi, whole) and
            Enum.all?(kinds, &(&1 not in shared))

        domain = %{kinds: kinds, value: value, exact?: exact?}
        acc = %{acc | domains: acc.domains ++ [domain]}

        cond do
          exact? -> acc
          required? -> widened(acc, loss_path)
          true -> %{acc | losses: acc.losses ++ [Bound.loss(:map_key_widened, loss_path)]}
        end
    end
  end

  defp widened(acc, loss_path) do
    %{acc | lo_empty?: true, losses: acc.losses ++ [Bound.loss(:map_key_widened, loss_path)]}
  end

  defp finite_atoms(%Bound{hi: hi} = key) do
    with true <- Bound.exact?(key),
         true <- Compiler.subtype?(hi, Compiler.atom()),
         {:finite, atoms} <- Compiler.atom_fetch(hi) do
      {:ok, Enum.sort(atoms)}
    else
      _ -> :error
    end
  end

  defp build_map(%{fields: fields, domains: domains} = acc) do
    value_bounds =
      Enum.map(fields, fn {_key, bound, _optional?} -> bound end) ++
        Enum.map(domains, & &1.value)

    hi_fields = for {key, bound, optional?} <- fields, do: {key, bound.hi, optional?}
    hi_domains = for %{kinds: [_ | _] = kinds, value: value} <- domains, do: {kinds, value.hi}

    # Lower bound: exact domains keep their lower value; an inexact optional
    # domain is dropped (maps without such keys still belong to S).
    lo =
      if acc.lo_empty? do
        Compiler.none()
      else
        lo_fields = for {key, bound, optional?} <- fields, do: {key, bound.lo, optional?}

        lo_domains =
          for %{kinds: [_ | _] = kinds, value: value, exact?: true} <- domains,
              do: {kinds, value.lo}

        Compiler.closed_map(lo_fields, lo_domains)
      end

    %Bound{
      lo: lo,
      hi: Compiler.closed_map(hi_fields, hi_domains),
      losses: Enum.uniq(acc.losses ++ Enum.flat_map(value_bounds, & &1.losses)),
      notes: Enum.uniq(Enum.flat_map(value_bounds, & &1.notes))
    }
  end

  ## Named types

  defp named(mod, name, args, ctx, path) do
    arity = length(args)
    key = {mod, name, arity}
    type_path = path ++ [{:type, mod, name, arity}]

    cond do
      key in ctx.stack or ctx.depth == 0 ->
        Bound.upper(Compiler.term(), :recursive_cutoff, type_path)

      true ->
        case TypeCache.fetch_type(ctx.cache, mod, name, arity) do
          {:ok, definition} -> expand(definition, key, args, ctx, path, type_path)
          {:error, _reason} -> Bound.upper(Compiler.term(), :unresolved_remote_type, type_path)
        end
    end
  end

  defp expand(%{kind: kind} = definition, {mod, _, _} = key, args, ctx, path, type_path) do
    boundary? = kind in [:opaque, :nominal] and mod != ctx.root

    cond do
      boundary? and not ctx.expand_opaque ->
        Bound.upper(Compiler.term(), boundary_loss(kind), type_path)

      boundary? ->
        bound = expand_body(definition, key, args, ctx, path)
        %{bound | notes: bound.notes ++ [%{kind: expanded_note(kind), path: type_path}]}

      true ->
        expand_body(definition, key, args, ctx, path)
    end
  end

  defp expand_body(%{params: params, body: body}, {mod, _, _} = key, args, ctx, path) do
    # Argument ASTs are written in the caller's module: qualify bare user
    # types before switching the context to the callee, or they would be
    # resolved in (or captured by) the callee's namespace.
    args = Enum.map(args, &qualify(&1, ctx.module))

    subst =
      params
      |> Enum.zip(args)
      |> Map.new(fn {{:var, _, param}, arg} -> {param, arg} end)

    inner = %{ctx | module: mod, stack: [key | ctx.stack], depth: ctx.depth - 1}
    node(substitute(body, subst), inner, path)
  end

  defp boundary_loss(:opaque), do: :opaque_boundary
  defp boundary_loss(:nominal), do: :nominal_boundary
  defp expanded_note(:opaque), do: :opaque_expanded
  defp expanded_note(:nominal), do: :nominal_expanded

  defp qualify({:user_type, line, name, args}, module) do
    {:remote_type, line,
     [{:atom, line, module}, {:atom, line, name}, Enum.map(args, &qualify(&1, module))]}
  end

  defp qualify({:type, line, name, args}, module) when is_list(args),
    do: {:type, line, name, Enum.map(args, &qualify(&1, module))}

  defp qualify({:remote_type, line, [mod, name, args]}, module),
    do: {:remote_type, line, [mod, name, Enum.map(args, &qualify(&1, module))]}

  defp qualify({:ann_type, line, [var, type]}, module),
    do: {:ann_type, line, [var, qualify(type, module)]}

  defp qualify(list, module) when is_list(list), do: Enum.map(list, &qualify(&1, module))
  defp qualify(other, _module), do: other

  # Keeps unsupported reasons small and free of source positions.
  defp strip(ast) do
    case ast do
      {kind, _line, a, b} -> {kind, strip(a), strip(b)}
      {kind, _line, a} when is_atom(kind) -> {kind, strip(a)}
      list when is_list(list) -> Enum.map(list, &strip/1)
      other -> other
    end
  end
end
