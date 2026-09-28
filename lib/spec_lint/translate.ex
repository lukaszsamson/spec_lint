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
    * Type variables are substituted by their bound (or `term()` when
      free). Occurrences are counted after `when` constraints are expanded,
      so correlation through constraint indirection is seen. A variable
      that occurs in the return and anywhere else makes the return keep only
      its upper bound (`:type_variable_correlation`). Any named variable
      inside an arrow argument, at any nesting, is inexact
      (`:type_variable_correlation`), so the enclosing arrow falls back to
      `fun(arity)` with `:arrow_polarity`: instantiating the variable with a
      smaller type yields a larger function type, so substituting the bound
      there would under-approximate. Variables whose every occurrence is
      covariant and outside the return stay exact: instantiating them with
      their bound maximises every occurrence at once, so the argument
      product at the bound is exactly the union over all instantiations.
    * Integer literals, ranges and refinements such as `pos_integer()` are
      `integer()` in `hi` with `:integer_refinement_erased` (the lattice has
      no integer literals); the intervals they denote are kept in the
      bound's `integers` so overlapping overloads can still be told apart.
    * Erlang records become open tuples tagged by the record name with
      `:record_fields_unknown`.
    * Map associations follow Dialyzer's reading (`erl_types`
      `map_from_form/6`): an earlier association shadows the keys it covers
      in later ones. See `map/3` below.
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
          expand_opaque: boolean(),
          in_arrow_arg: boolean()
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
      expand_opaque: Keyword.get(opts, :expand_opaque, false),
      in_arrow_arg: false
    }
  end

  @doc "Translates one spec clause (one slice)."
  @spec slice(tuple(), context()) :: {:ok, slice()} | {:unsupported, term()}
  def slice(clause_ast, context) do
    {fun_ast, constraints} = debound(clause_ast)

    case fun_ast do
      {:type, _, :fun, [{:type, _, :product, args}, return]} ->
        subst = constraint_substitution(constraints)
        args = Enum.map(args, &substitute_all(&1, subst))
        return = substitute_all(return, subst)
        correlated = correlated_vars(args, return)

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
  Upper bounds of the arguments of a spec clause, translated one position
  at a time, for a slice `slice/2` reports unsupported: an overload whose
  return or one argument cannot be translated still has a domain that can
  be shown disjoint from its siblings' (`SpecLint.Compare.function/3`).

  Each argument is translated on its own; `hi` of each is an upper bound
  of that argument whatever the other positions are. A position whose
  translation fails is `term()` with an `:unsupported_construct` loss.
  `:error` when the clause has no argument list to translate (not a
  function type, or an unsupported `when` constraint).
  """
  @spec argument_bounds(tuple(), context()) :: {:ok, [Bound.t()]} | :error
  def argument_bounds(clause_ast, context) do
    {fun_ast, constraints} = debound(clause_ast)

    case fun_ast do
      {:type, _, :fun, [{:type, _, :product, args}, _return]} ->
        subst = constraint_substitution(constraints)

        bounds =
          args
          |> Enum.with_index()
          |> Enum.map(fn {arg, index} ->
            path = [{:arg, index}]

            case type(substitute_all(arg, subst), context, path) do
              {:ok, bound} ->
                bound

              {:unsupported, _reason} ->
                Bound.upper(Compiler.term(), :unsupported_construct, path)
            end
          end)

        {:ok, bounds}

      _other ->
        :error
    end
  catch
    {:unsupported, _reason} -> :error
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

  # Each constrained variable is replaced by a marker that keeps its name
  # next to its bound, so occurrences can still be counted after expansion.
  defp constraint_substitution(constraints) do
    Map.new(constraints, fn
      {:type, _, :constraint, [{:atom, _, :is_subtype}, [{:var, _, name}, type]]} ->
        {name, {:spec_lint_var, 0, name, type}}

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
    cutoff = Map.new(subst, fn {name, _marker} -> {name, {:spec_lint_cutoff, name}} end)
    substitute(ast, cutoff)
  end

  defp substitute_all(ast, subst, budget) do
    next = substitute(ast, subst)
    if next == ast, do: ast, else: substitute_all(next, subst, budget - 1)
  end

  # Variables that occur in the return and at least one more time anywhere in
  # the clause (the return may be restricted per call). Counted on the
  # expanded clause, so `f(x) :: y when x: [a], y: a` correlates through `a`.
  defp correlated_vars(args, return) do
    in_return = occurrences(return)
    counts = Enum.frequencies(Enum.flat_map(args, &occurrences/1) ++ in_return)

    in_return
    |> Enum.uniq()
    |> Enum.filter(&(Map.fetch!(counts, &1) >= 2))
  end

  defp occurrences({:spec_lint_var, _, name, type}), do: [name | occurrences(type)]
  defp occurrences({:spec_lint_cutoff, name}), do: [name]
  defp occurrences({:ann_type, _, [_name, type]}), do: occurrences(type)
  defp occurrences({:var, _, :_}), do: []
  defp occurrences({:var, _, name}), do: [name]
  defp occurrences(list) when is_list(list), do: Enum.flat_map(list, &occurrences/1)

  defp occurrences(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> occurrences()

  defp occurrences(_other), do: []

  defp substitute({:var, _, name} = var, subst), do: Map.get(subst, name, var)

  defp substitute({:spec_lint_var, line, name, type}, subst),
    do: {:spec_lint_var, line, name, substitute(type, subst)}

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
  defp node({:integer, _, _} = ast, _ctx, path), do: literal_integer(ast, path)
  defp node({:char, _, _} = ast, _ctx, path), do: literal_integer(ast, path)
  defp node({:op, _, _, _} = ast, _ctx, path), do: literal_integer(ast, path)
  defp node({:op, _, _, _, _} = ast, _ctx, path), do: literal_integer(ast, path)

  defp node({:spec_lint_cutoff, _name}, _ctx, path),
    do: Bound.upper(Compiler.term(), :recursive_cutoff, path)

  # A constrained type variable: its bound, marked when inside an arrow
  # argument.
  defp node({:spec_lint_var, _, _name, type}, ctx, path),
    do: variable(node(type, ctx, path), ctx, path)

  # Type variables left after `when` substitution and parameter substitution
  # are unconstrained: any term. `_` is `term()` and not a variable.
  defp node({:var, _, :_}, _ctx, _path), do: exact(Compiler.term())
  defp node({:var, _, _}, ctx, path), do: variable(exact(Compiler.term()), ctx, path)

  defp node({:remote_type, _, [{:atom, _, mod}, {:atom, _, name}, args]}, ctx, path),
    do: named(mod, name, args, ctx, path)

  defp node({:user_type, _, name, args}, ctx, path), do: named(ctx.module, name, args, ctx, path)
  defp node({:type, _, name, args}, ctx, path), do: builtin(name, args, ctx, path)
  defp node(other, _ctx, _path), do: throw({:unsupported, {:construct, strip(other)}})

  defp exact(descr), do: Bound.exact(descr)

  # Inside an arrow argument a variable ranges contravariantly: the smallest
  # instance gives the largest function type, so the bound is not an upper
  # bound of the arrow. Marking the occurrence inexact makes the arrow fall
  # back to fun(arity).
  defp variable(bound, %{in_arrow_arg: true}, path),
    do: %{Bound.add_loss(bound, :type_variable_correlation, path) | lo: Compiler.none()}

  defp variable(bound, _ctx, _path), do: bound

  # The lattice has no integer literals or ranges: every refinement is
  # erased to integer() in hi, and the interval it denotes is kept in
  # `integers` (see SpecLint.Bound).
  defp refined_integer(path, intervals \\ nil),
    do: %{Bound.upper(Compiler.integer(), :integer_refinement_erased, path) | integers: intervals}

  defp literal_integer(ast, path) do
    case integer_value(ast) do
      {:ok, value} -> refined_integer(path, [{value, value}])
      :error -> refined_integer(path)
    end
  end

  # Value of an integer literal expression in a typespec (`1`, `?a`, `-1`,
  # `1 + 2`, ...), or :error for anything else.
  defp integer_value({:integer, _, value}) when is_integer(value), do: {:ok, value}
  defp integer_value({:char, _, value}) when is_integer(value), do: {:ok, value}

  defp integer_value({:op, _, op, arg}) when op in [:-, :+, :bnot] do
    with {:ok, value} <- integer_value(arg), do: {:ok, unary(op, value)}
  end

  defp integer_value({:op, _, op, left, right}) do
    with {:ok, l} <- integer_value(left),
         {:ok, r} <- integer_value(right) do
      binary(op, l, r)
    end
  end

  defp integer_value(_ast), do: :error

  defp unary(:-, value), do: -value
  defp unary(:+, value), do: value
  defp unary(:bnot, value), do: Bitwise.bnot(value)

  defp binary(:+, l, r), do: {:ok, l + r}
  defp binary(:-, l, r), do: {:ok, l - r}
  defp binary(:*, l, r), do: {:ok, l * r}
  defp binary(:div, l, r) when r != 0, do: {:ok, div(l, r)}
  defp binary(:rem, l, r) when r != 0, do: {:ok, rem(l, r)}
  defp binary(:band, l, r), do: {:ok, Bitwise.band(l, r)}
  defp binary(:bor, l, r), do: {:ok, Bitwise.bor(l, r)}
  defp binary(:bxor, l, r), do: {:ok, Bitwise.bxor(l, r)}
  defp binary(_op, _l, _r), do: :error

  defp range_integer(first, last, path) do
    case {integer_value(first), integer_value(last)} do
      {{:ok, first}, {:ok, last}} when first <= last -> refined_integer(path, [{first, last}])
      _ -> refined_integer(path)
    end
  end

  ## Builtin types

  defp builtin(:union, members, ctx, path) do
    bounds =
      members
      |> Enum.with_index()
      |> Enum.map(fn {member, index} -> node(member, ctx, path ++ [{:union, index}]) end)

    union = Bound.map_covariant(bounds, &Compiler.union_all/1)

    if Enum.any?(bounds, &is_list(&1.integers)),
      do: %{union | integers: Enum.flat_map(bounds, &Bound.integer_intervals/1)},
      else: union
  end

  defp builtin(name, [], _ctx, _path) when name in [:term, :any, :dynamic],
    do: exact(Compiler.term())

  defp builtin(name, [], _ctx, _path) when name in [:none, :no_return],
    do: exact(Compiler.none())

  defp builtin(name, [], _ctx, _path) when name in [:atom, :module, :node],
    do: exact(Compiler.atom())

  defp builtin(:boolean, [], _ctx, _path), do: exact(Compiler.boolean())
  defp builtin(:integer, [], _ctx, _path), do: exact(Compiler.integer())

  defp builtin(:non_neg_integer, [], _ctx, path), do: refined_integer(path, [{0, :infinity}])
  defp builtin(:pos_integer, [], _ctx, path), do: refined_integer(path, [{1, :infinity}])
  defp builtin(:neg_integer, [], _ctx, path), do: refined_integer(path, [{:neg_infinity, -1}])

  defp builtin(name, [], _ctx, path) when name in [:arity, :byte],
    do: refined_integer(path, [{0, 255}])

  defp builtin(:char, [], _ctx, path), do: refined_integer(path, [{0, 0x10FFFF}])
  defp builtin(:range, [first, last], _ctx, path), do: range_integer(first, last, path)
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
      losses: [Bound.loss(:integer_refinement_erased, path ++ [{:union, 1}])],
      integers: [{0, :infinity}]
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
    arg_ctx = %{ctx | in_arrow_arg: true}

    arg_bounds =
      args
      |> Enum.with_index()
      |> Enum.map(fn {arg, index} -> node(arg, arg_ctx, path ++ [{:fun_arg, index}]) end)

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
      # only sound upper bound is the top function of this arity. The child
      # losses are kept as the reason for the fallback.
      children = arg_bounds ++ [return_bound]

      %Bound{
        lo: Compiler.none(),
        hi: Compiler.fun(length(args)),
        losses: [Bound.loss(:arrow_polarity, path) | Enum.flat_map(children, & &1.losses)],
        notes: Enum.flat_map(children, & &1.notes)
      }
    end
  end

  ## Maps

  # Literal map types are closed. Associations are read in order, as
  # Dialyzer does (`erl_types` `map_from_form/6`): keys already covered by
  # an earlier association are removed from later ones, so the first
  # association for a key wins. A literal atom key after `optional(atom())`
  # is therefore shadowed, and `%{:__struct__ => atom(), optional(atom()) =>
  # any()}` keeps `__struct__` as an `atom()` field.
  #
  # A non-literal key is split into its finite atom part (one optional field
  # per atom) and whole base kinds (key domains). Its coverage is `certain`
  # when the key is exact and the kinds are whole, otherwise `possible`: the
  # upper bound covers more keys than the spec does. A later association
  # that meets a `possible` entry may still apply there, so both values are
  # joined in the upper bound and the lower bound becomes `none()`. Required
  # non-literal keys other than a single atom are widened to optional in the
  # upper bound with `lo = none()`. Every widening records `:map_key_widened`.
  defp map(assocs, ctx, path) do
    acc = %{fields: [], domains: [], values: [], losses: [], lo_empty?: false}

    assocs
    |> Enum.with_index()
    |> Enum.map(fn {assoc, index} -> map_entry(assoc, index, ctx, path) end)
    |> Enum.reduce(acc, &add_assoc/2)
    |> build_map()
  end

  defp map_entry({:type, _, kind, [key, value]}, index, ctx, path)
       when kind in [:map_field_exact, :map_field_assoc] do
    required? = kind == :map_field_exact

    case key do
      {:atom, _, atom} ->
        value_bound = node(value, ctx, path ++ [{:map_value, atom}])
        {:literal, atom, value_bound, required?, path ++ [{:map_value, atom}]}

      _ ->
        key_bound = node(key, ctx, path ++ [{:map_key, index}])
        value_bound = node(value, ctx, path ++ [{:map_value, index}])
        {:domain, key_bound, value_bound, required?, path ++ [{:map_key, index}]}
    end
  end

  defp map_entry(other, _index, _ctx, _path),
    do: throw({:unsupported, {:map_association, strip(other)}})

  defp add_assoc({:literal, atom, value, required?, loss_path}, acc) do
    acc = %{acc | values: acc.values ++ [value]}
    add_field(acc, atom, value, not required?, true, loss_path)
  end

  defp add_assoc({:domain, key, value, required?, loss_path}, acc) do
    acc = %{acc | values: acc.values ++ [value], losses: acc.losses ++ key.losses}
    certain? = Bound.exact?(key)
    {atoms, rest} = split_key(key.hi)
    single_required? = required? and certain? and match?([_], atoms) and Compiler.empty?(rest)

    acc =
      Enum.reduce(atoms, acc, fn atom, acc ->
        add_field(acc, atom, value, not single_required?, certain?, loss_path)
      end)

    kinds = Compiler.key_kinds(rest)

    whole? =
      Compiler.equal?(rest, Compiler.union_all(Enum.map(kinds, &Compiler.key_kind_descr/1)))

    acc = Enum.reduce(kinds, acc, &add_domain(&2, &1, value, certain? and whole?, loss_path))

    exact? = certain? and whole?
    record_key_loss(acc, required? and not single_required?, exact?, loss_path)
  end

  # A required key other than a single atom is optional in hi, so lo is
  # none(); otherwise an inexact key only widens hi.
  defp record_key_loss(acc, true = _widened_required?, _exact?, loss_path),
    do: widened(acc, loss_path)

  defp record_key_loss(acc, false, true = _exact?, _loss_path), do: acc
  defp record_key_loss(acc, false, false, loss_path), do: widened_hi(acc, loss_path)

  # Splits a key into its finite atoms (sorted) and the rest. A whole or
  # co-finite atom part stays in the rest and is covered by the atom kind.
  defp split_key(key) do
    atom_part = Compiler.intersection(key, Compiler.atom())
    rest = Compiler.difference(key, Compiler.atom())

    case Compiler.atom_fetch(atom_part) do
      {:finite, atoms} -> {Enum.sort(atoms), rest}
      {:infinite, _} -> {[], Compiler.union(rest, atom_part)}
      :error -> {[], rest}
    end
  end

  # A required key shadowed by an earlier field still makes that field
  # required (`promote_to_mand/2` in erl_types).
  defp add_field(acc, atom, value, optional?, certain?, loss_path) do
    case {field(acc, atom), domain(acc, :atom)} do
      {%{certain?: true} = field, _} ->
        if optional?, do: acc, else: put_field(acc, %{field | optional?: false})

      {nil, %{certain?: true}} ->
        acc

      {%{} = field, _} ->
        joined = %{field | hi: Compiler.union(field.hi, value.hi), optional?: true}
        widened(put_field(acc, joined), loss_path)

      {nil, %{} = domain} ->
        joined = new_field(atom, Compiler.union(domain.hi, value.hi), value.lo, true, false)
        widened(put_field(acc, joined), loss_path)

      {nil, nil} ->
        put_field(acc, new_field(atom, value.hi, value.lo, optional?, certain?))
    end
  end

  defp add_domain(acc, kind, value, certain?, loss_path) do
    case domain(acc, kind) do
      %{certain?: true} ->
        acc

      %{} = domain ->
        joined = %{domain | hi: Compiler.union(domain.hi, value.hi)}
        widened(put_domain(acc, joined), loss_path)

      nil ->
        acc = put_domain(acc, %{kind: kind, hi: value.hi, lo: value.lo, certain?: certain?})
        if kind == :atom, do: join_possible_fields(acc, value, loss_path), else: acc
    end
  end

  # A field from an inexact key may not be covered by the spec at all, in
  # which case a later atom domain applies to that key too.
  defp join_possible_fields(acc, value, loss_path) do
    Enum.reduce(acc.fields, acc, fn
      %{certain?: false} = field, acc ->
        joined = %{field | hi: Compiler.union(field.hi, value.hi), optional?: true}
        widened(put_field(acc, joined), loss_path)

      _field, acc ->
        acc
    end)
  end

  defp new_field(atom, hi, lo, optional?, certain?),
    do: %{key: atom, hi: hi, lo: lo, optional?: optional?, certain?: certain?}

  defp field(acc, atom), do: Enum.find(acc.fields, &(&1.key == atom))
  defp domain(acc, kind), do: Enum.find(acc.domains, &(&1.kind == kind))

  defp put_field(acc, %{key: key} = field) do
    case Enum.find_index(acc.fields, &(&1.key == key)) do
      nil -> %{acc | fields: acc.fields ++ [field]}
      index -> %{acc | fields: List.replace_at(acc.fields, index, field)}
    end
  end

  defp put_domain(acc, %{kind: kind} = domain) do
    case Enum.find_index(acc.domains, &(&1.kind == kind)) do
      nil -> %{acc | domains: acc.domains ++ [domain]}
      index -> %{acc | domains: List.replace_at(acc.domains, index, domain)}
    end
  end

  defp widened(acc, loss_path),
    do: %{widened_hi(acc, loss_path) | lo_empty?: true}

  defp widened_hi(acc, loss_path) do
    loss = Bound.loss(:map_key_widened, loss_path)
    if loss in acc.losses, do: acc, else: %{acc | losses: acc.losses ++ [loss]}
  end

  # Lower bound: only `certain` entries, with their lower values. Leaving out
  # a `possible` (always optional) entry is sound: maps without those keys
  # still belong to S.
  defp build_map(acc) do
    hi_fields = for field <- acc.fields, do: {field.key, field.hi, field.optional?}
    hi_domains = for domain <- acc.domains, do: {[domain.kind], domain.hi}

    lo =
      if acc.lo_empty? do
        Compiler.none()
      else
        lo_fields = for %{certain?: true} = f <- acc.fields, do: {f.key, f.lo, f.optional?}
        lo_domains = for %{certain?: true} = d <- acc.domains, do: {[d.kind], d.lo}
        Compiler.closed_map(lo_fields, lo_domains)
      end

    %Bound{
      lo: lo,
      hi: Compiler.closed_map(hi_fields, hi_domains),
      losses: Enum.uniq(acc.losses ++ Enum.flat_map(acc.values, & &1.losses)),
      notes: Enum.uniq(Enum.flat_map(acc.values, & &1.notes))
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

  defp qualify({:spec_lint_var, line, name, type}, module),
    do: {:spec_lint_var, line, name, qualify(type, module)}

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
