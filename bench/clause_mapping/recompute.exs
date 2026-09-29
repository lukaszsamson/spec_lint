# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2021 The Elixir Team
# SPDX-FileCopyrightText: 2012 Plataformatec
#
# Contains an instrumented adaptation of Elixir c24c235 Module.Types.
# Modified: records source-clause mappings and inference modes, handles missing
# local definitions, and provides the surrounding diagnostic solver/report.
# Source attribution and license: THIRD_PARTY_NOTICES.md and LICENSE.

# Source-clause mapping diagnostic (Milestone 4). Not part of the product.
#
# For every public function of a module, maps each clause of the signature
# stored in the ExCk chunk back to the source clauses (debug info) it came
# from, in two independent ways:
#
#   * Mode A ("heads"): no body inference. The source clause head domains
#     are recomputed with the checker's own pattern typing
#     (Module.Types.Pattern.of_head/8 in :infer mode, with the same
#     previous-clause chain), and a constraint search finds every
#     assignment source clause -> stored clause | dropped that satisfies
#     the invariants of the compiler pipeline (README.md, "Invariants").
#     A stored clause is :exact when every satisfying assignment gives it
#     the same source clauses. The structural classes (one source clause,
#     a {:super, ...} clause, as many stored as source clauses) are decided
#     first, from clause counts alone. Four typed variants
#     (ClauseMapping.Solver) handle the rest: strict_inv / strict_a1 take
#     the recomputed heads as the compiler's; robust_inv / robust_a1 only
#     use them as bounds. *_a1 also use assumption A1 (a body never empties
#     a non-empty head argument type). README.md shows that neither kind is
#     justified for heads (E1-E3, and the review counterexamples R1-R2):
#     their exact claims are unverified; only the structural classes follow
#     from invariants alone (adopted in lib/spec_lint/clause_mapping.ex).
#
#   * Mode B ("replay"): an instrumented copy of the orchestration in
#     Module.Types.infer/7 (c24c235) re-infers the whole module and records
#     the compiler's own source -> inferred mapping, then
#     group_clauses_by_return with index tracking. It is used as an oracle
#     only where the replayed signature equals the stored one.
#
# Only Elixir c24c235 is supported: the replay copies its types.ex, and
# the script exits 2 at startup under any other compiler (checked with
# SpecLint.Compiler.preflight/0, which also verifies the build's identity).
#
# Usage (run with c24c235 on PATH and a build of SpecLint on -pa; see
# bench/clause_mapping/run.sh and README.md):
#
#   elixir -pa TOOL_EBIN bench/clause_mapping/recompute.exs fixtures OUT.json
#   elixir -pa TOOL_EBIN bench/clause_mapping/recompute.exs corpus \
#     --label NAME --ebin DIR [--ebin DIR] [--code-path DIR ...] --out OUT.json \
#     [--focus Mod.fun/arity ...]

defmodule ClauseMapping.Replay do
  @moduledoc false
  # Copy of Module.Types (Elixir c24c235, lib/elixir/lib/module/types.ex)
  # infer/7 (37-126), infer_mode/2, protocol?/1, impl_for/1,
  # default_domain/4 (128-169), local_handler/5,7 (288-338),
  # default_local_handler/9 (340-394), infer_local_handler/7 (396-441),
  # group_clauses/1 (443-493), compute_domain/4 (495-548),
  # add_inferred/5 (552-559), with_file_meta/2, fresh_stack/3,
  # fresh_context/1, restore_context/2. Changes: undefined functions return
  # false without a module error; the per-clause triples, the mapping and
  # the handler used are recorded per definition in the process dictionary.
  alias Module.Types.{Apply, Descr, Expr, Helpers, Of, Pattern, Traverse}

  @no_infer [behaviour_info: 1]

  @doc "Re-infers `defs`; returns the inferred signatures and the recorded table."
  @spec run(module(), String.t(), keyword(), [tuple()], term()) :: {map(), map()}
  def run(module, file, attrs, defs, cache) do
    Process.put(__MODULE__, %{})
    impl = impl_for(attrs)
    finder = &find_definition(defs, &1, impl)
    handler = &checked_handler(&1, &2, &3, &4, finder)
    stack = Module.Types.stack(:infer, file, module, {:__info__, 1}, :all, cache, handler)

    {types, _context} =
      defs
      |> Enum.sort()
      |> Enum.reduce({[], Module.Types.context()}, &infer_definition(&1, &2, stack, impl))

    {Map.new(types), Process.delete(__MODULE__)}
  end

  defp find_definition(defs, fun_arity, impl) do
    case :lists.keyfind(fun_arity, 1, defs) do
      {_, kind, _, _} = def -> default_domain(infer_mode(kind), def, fun_arity, impl)
      false -> false
    end
  end

  defp checked_handler(meta, fun_arity, stack, context, finder) do
    case local_handler(meta, fun_arity, stack, context, finder) do
      {kind, _, _} = triplet when kind in [:defmacro, :defmacrop] ->
        if Keyword.has_key?(meta, :super), do: triplet, else: false

      other ->
        other
    end
  end

  defp infer_definition({fun_arity, kind, meta, _clauses} = def, {types, context}, stack, impl)
       when kind in [:def, :defmacro] do
    finder = fn _ -> default_domain(infer_mode(kind), def, fun_arity, impl) end
    {_kind, inferred, context} = local_handler(meta, fun_arity, stack, context, finder)

    if kind == :def and fun_arity not in @no_infer,
      do: {[{fun_arity, inferred} | types], context},
      else: {types, context}
  end

  defp infer_definition(_def, acc, _stack, _impl), do: acc

  @doc "Whether the module is a protocol (the compiler infers nothing for it)."
  @spec protocol?(keyword()) :: boolean()
  def protocol?(attrs), do: List.keymember?(attrs, :__protocol__, 0)

  defp infer_mode(kind), do: if(kind in [:def, :defp], do: :infer, else: :traverse)

  @doc "The protocol implementation the attributes declare, as `infer/7` reads it."
  @spec impl_for(keyword()) :: {module(), [{atom(), arity()}]} | nil
  def impl_for(attrs) do
    case List.keyfind(attrs, :__impl__, 0) do
      {:__impl__, [protocol: protocol, for: for]} ->
        if Code.ensure_loaded?(protocol) and function_exported?(protocol, :__protocol__, 1) do
          {for, protocol.__protocol__(:functions)}
        else
          nil
        end

      _ ->
        nil
    end
  end

  @doc "The expected argument types of a definition (`default_domain/4` of the compiler)."
  @spec default_domain(atom(), tuple(), {atom(), arity()}, term()) :: {atom(), tuple(), list()}
  def default_domain(mode, def, {_, arity} = fun_arity, impl) do
    with {for, callbacks} <- impl,
         true <- fun_arity in callbacks do
      args = [
        Descr.dynamic(Of.impl(for))
        | List.duplicate(Descr.dynamic(), arity - 1)
      ]

      {_fun_arity, kind, meta, clauses} = def

      clauses =
        for {meta, args, guards, body} <- clauses do
          {[type_check: {:impl, for}] ++ meta, args, guards, body}
        end

      {mode, {fun_arity, kind, meta, clauses}, args}
    else
      _ -> {mode, def, List.duplicate(Descr.dynamic(), arity)}
    end
  end

  defp local_handler(_meta, fun_arity, stack, context, finder) do
    case context.local_sigs do
      %{^fun_arity => {kind, inferred, _mapping}} ->
        {kind, inferred, context}

      %{^fun_arity => kind} when is_atom(kind) ->
        {kind, :none, context}

      local_sigs ->
        case finder.(fun_arity) do
          {mode, {fun_arity, kind, _meta, clauses}, expected} ->
            context = put_in(context.local_sigs, Map.put(local_sigs, fun_arity, kind))

            {inferred, mapping, context} =
              local_handler(mode, fun_arity, kind, clauses, expected, stack, context)

            context =
              update_in(context.local_sigs, &Map.put(&1, fun_arity, {kind, inferred, mapping}))

            {kind, inferred, context}

          false ->
            false
        end
    end
  end

  defp local_handler(:traverse, {_, arity} = fun_arity, _kind, clauses, _expected, stack, context) do
    context =
      Enum.reduce(clauses, context, fn {meta, _args, _guards, body}, context ->
        stack = with_file_meta(stack, meta)
        Traverse.of_expr(body, stack, context)
      end)

    record(fun_arity, %{handler: :traverse})
    inferred = {:infer, nil, [{List.duplicate(Descr.term(), arity), Descr.dynamic()}]}
    {inferred, [{0, 0}], context}
  end

  defp local_handler(mode, fun_arity, kind, clauses, expected, stack, context) do
    {fun, _arity} = fun_arity
    stack = fresh_stack(stack, mode, fun_arity)
    base_info = {:def, kind, fun, expected}

    case clauses do
      [{meta, args, [], {:super, _, [_ | _]} = body}] ->
        default_local_handler(
          fun_arity,
          meta,
          args,
          body,
          base_info,
          expected,
          stack,
          context
        )

      _ ->
        infer_local_handler(fun_arity, clauses, base_info, expected, stack, context)
    end
  end

  defp default_local_handler(fun_arity, meta, args, body, base_info, expected, stack, context) do
    stack = with_file_meta(stack, meta)
    guards = []
    previous = Pattern.init_previous()
    fresh_context = fresh_context(context)
    info = {base_info, args, guards}

    {trees, _, _, _, _, head_context} =
      Pattern.of_head(args, guards, expected, previous, info, meta, stack, fresh_context)

    {:super, meta, call_args} = body
    {_kind, call_fun} = Keyword.fetch!(meta, :super)
    term = Descr.term()
    of_fun = &Expr.of_expr/5

    {arrows, body_context} =
      Apply.local_arrows(call_fun, call_args, term, body, stack, head_context, of_fun)

    {_, _, mapping, inferred} =
      Enum.reduce(arrows, {0, 0, [], []}, fn
        {clause_domain, return_type}, {index, total, mapping, inferred} ->
          of_fun = &Expr.of_expr(&1, &2, body, stack, &3)

          {_clause_args, clause_context} =
            Helpers.zip_map_reduce(call_args, clause_domain, head_context, of_fun)

          clause_types = Pattern.of_domain(trees, stack, clause_context)

          {type_index, inferred} =
            add_inferred(inferred, clause_types, return_type, total - 1, [])

          total = if type_index == -1, do: total + 1, else: total
          {index + 1, total, [{0, index} | mapping], inferred}
      end)

    domain =
      case inferred do
        [_] ->
          nil

        _ ->
          inferred
          |> Enum.map(fn {args, _} -> args end)
          |> Enum.zip_with(fn types -> Enum.reduce(types, &Descr.opt_union/2) end)
      end

    record(fun_arity, %{handler: :super, super: call_fun, arrows: length(arrows)})
    {{:infer, domain, Enum.reverse(inferred)}, mapping, restore_context(body_context, context)}
  end

  defp infer_local_handler(fun_arity, clauses, base_info, expected, stack, context) do
    saved_heads = Process.put({__MODULE__, :heads}, [])

    {_, clauses_types, clauses_context} =
      Enum.reduce(clauses, {Pattern.init_previous(), [], context}, fn
        {meta, args, guards, body}, {previous, inferred, acc_context} ->
          stack = with_file_meta(stack, meta)
          fresh_context = fresh_context(acc_context)
          info = {base_info, args, guards}

          {trees, precise?, _errored?, head_no_previous_args_types, previous, head_context} =
            Pattern.of_head(args, guards, expected, previous, info, meta, stack, fresh_context)

          {return_type, context} =
            Expr.of_expr(body, Descr.term(), body, stack, head_context)

          args_types = Pattern.of_domain(trees, stack, context)

          head_args_types =
            case inferred do
              [] -> nil
              _ -> Pattern.of_domain(trees, stack, head_context)
            end

          args_triplet = {args_types, head_args_types, head_no_previous_args_types}
          inferred = [{args_triplet, return_type, precise?} | inferred]
          # Instrumentation only: the head domain of every clause, including
          # the first (the compiler leaves head_args_types nil there).
          record_head(Pattern.of_domain(trees, stack, head_context))
          {previous, inferred, context}
      end)

    ordered = Enum.reverse(clauses_types)
    heads = Enum.reverse(Process.put({__MODULE__, :heads}, saved_heads) || [])
    {clauses_types, mapping, domain} = group_clauses(ordered)

    domain =
      case clauses_types do
        [_] -> nil
        _ -> domain
      end

    record(fun_arity, %{
      handler: :infer,
      clauses:
        Enum.zip_with(ordered, heads, fn {{args, _head_args, _}, return, precise?}, head ->
          %{args: args, head: head, return: return, precise: precise?}
        end),
      mapping: mapping
    })

    inferred = {:infer, domain, clauses_types}
    {inferred, mapping, restore_context(clauses_context, context)}
  end

  defp group_clauses(clauses) do
    {_, all_clauses, filtered_clauses, non_empty?} =
      Enum.reduce(clauses, {0, [], [], false}, fn
        {_args_triplet, return, precise?} = clause,
        {index, all_clauses, filtered_clauses, non_empty?} ->
          empty? = Descr.empty?(return)
          indexed_clause = {clause, index}

          filtered_clauses =
            if precise? and empty? do
              filtered_clauses
            else
              [indexed_clause | filtered_clauses]
            end

          {index + 1, [indexed_clause | all_clauses], filtered_clauses, non_empty? or not empty?}
      end)

    clauses =
      if non_empty? do
        Enum.reverse(filtered_clauses)
      else
        Enum.reverse(all_clauses)
      end

    [
      {{{args, _head_args, _head_no_previous_args}, _return, _precise?}, _index}
      | clauses_tail
    ] = clauses

    domain =
      Enum.reduce(clauses_tail, args, fn
        {{{args, head_args, head_no_previous_args}, _return, _precise?}, _index}, domain ->
          compute_domain(args, head_args, head_no_previous_args, domain)
      end)

    {_, mapping, inferred} =
      Enum.reduce(clauses, {0, [], []}, fn
        {{{args, _head_args, _head_no_previous_args}, return, _precise?}, index},
        {total, mapping, inferred} ->
          {type_index, inferred} = add_inferred(inferred, args, return, total - 1, [])

          if type_index == -1 do
            {total + 1, [{index, total} | mapping], inferred}
          else
            {total, [{index, type_index} | mapping], inferred}
          end
      end)

    {Enum.reverse(inferred), mapping, domain}
  end

  defp compute_domain(
         [arg | args_types],
         [head_arg | head_args_types],
         [no_prev_arg | no_prev_args_types],
         [d | domain]
       ) do
    [
      if arg == head_arg do
        Descr.opt_union(Descr.upper_bound(no_prev_arg), d)
      else
        Descr.opt_union(arg, d)
      end
      | compute_domain(args_types, head_args_types, no_prev_args_types, domain)
    ]
  end

  defp compute_domain([], [], [], []), do: []

  defp add_inferred([{args, existing_return} | tail], args, return, index, acc),
    do: {index, Enum.reverse(acc, [{args, Descr.opt_union(existing_return, return)} | tail])}

  defp add_inferred([head | tail], args, return, index, acc),
    do: add_inferred(tail, args, return, index - 1, [head | acc])

  defp add_inferred([], args, return, -1, acc),
    do: {-1, [{args, return} | Enum.reverse(acc)]}

  @doc "The stack with the clause's file, as the compiler sets it."
  @spec with_file_meta(map(), keyword()) :: map()
  def with_file_meta(stack, meta) do
    case Keyword.fetch(meta, :file) do
      {:ok, {meta_file, _}} -> %{stack | file: meta_file}
      :error -> stack
    end
  end

  defp fresh_stack(stack, mode, function),
    do: %{stack | mode: mode, function: function, reverse_arrow: nil}

  defp fresh_context(context), do: %{context | vars: %{}, failed: false, reverse_arrows: %{}}

  defp restore_context(later_context, %{
         vars: vars,
         failed: failed,
         reverse_arrows: reverse_arrows
       }) do
    %{later_context | vars: vars, failed: failed, reverse_arrows: reverse_arrows}
  end

  # Nested inference (a local call inside a body) saves and restores the
  # accumulator, so each definition sees only its own clause heads.
  defp record_head(head) do
    Process.put({__MODULE__, :heads}, [head | Process.get({__MODULE__, :heads}, [])])
  end

  defp record(fun_arity, info) do
    table = Process.get(__MODULE__, %{})

    unless Map.has_key?(table, fun_arity),
      do: Process.put(__MODULE__, Map.put(table, fun_arity, info))
  end

  # group_clauses_by_return/1 (types.ex:571-611) with index tracking: each
  # output clause carries the indexes of the inferred clauses merged into it.
  @doc "`group_clauses_by_return/1` of the compiler, with the merged indexes."
  @spec group_by_return_tracked(tuple()) :: {tuple(), [[non_neg_integer()]]}
  def group_by_return_tracked({:infer, domain, [{[_ | _], _} | _] = clauses}) do
    grouped =
      clauses
      |> Enum.with_index()
      |> Enum.reduce([], fn {{args, return}, index}, acc ->
        group_clause_by_return(acc, args, return, index)
      end)

    {{:infer, domain, Enum.map(grouped, fn {args, return, _} -> {args, return} end)},
     Enum.map(grouped, fn {_, _, indexes} -> Enum.reverse(indexes) end)}
  end

  def group_by_return_tracked({:infer, _domain, clauses} = info),
    do: {info, Enum.map(Enum.with_index(clauses), fn {_, index} -> [index] end)}

  defp group_clause_by_return([{existing_args, return, indexes} | tail], args, return, index) do
    case union_args(existing_args, args, [], false) do
      nil ->
        [{existing_args, return, indexes} | group_clause_by_return(tail, args, return, index)]

      new_args ->
        [{new_args, return, [index | indexes]} | tail]
    end
  end

  defp group_clause_by_return([head | tail], args, return, index),
    do: [head | group_clause_by_return(tail, args, return, index)]

  defp group_clause_by_return([], args, return, index), do: [{args, return, [index]}]

  defp union_args([arg | existing], [arg | args], acc, changed?),
    do: union_args(existing, args, [arg | acc], changed?)

  defp union_args([existing_arg | existing], [arg | args], acc, false),
    do: union_args(existing, args, [Descr.opt_union(existing_arg, arg) | acc], true)

  defp union_args([_ | _], [_ | _], _acc, true), do: nil
  defp union_args([], [], acc, _changed?), do: Enum.reverse(acc)
end

defmodule ClauseMapping.Heads do
  @moduledoc false
  # Mode A input, computed without inferring any body. Per source clause:
  #
  #   * `lo`: the head domain the checker computes before the body
  #     (Pattern.of_domain over the head context, as infer_local_handler
  #     does for head_args_types), threading `previous` as the compiler
  #     does, in a fresh context, with the closed struct type for a
  #     protocol implementation's first argument;
  #   * `precise`: the precise? flag of that run;
  #   * `hi`: the same head with no previous clauses and the open struct
  #     type for an implementation's first argument.
  #
  # The compiler's own run is not in a fresh context: `subpatterns` is not
  # reset between clauses or definitions (types.ex:708-710), and a leaked
  # {:list, version} entry makes a guard on that variable imprecise
  # (pattern.ex:990, 1226-1229), so the compiler may subtract fewer
  # previous clauses than the fresh run. Of.impl/2 (of.ex:289-301) gives
  # the closed struct type only when the struct module is loaded at compile
  # time. The robust variants were built on the hypothesis
  # lo <= compiler head <= hi; it is false (README.md, E3: subtracting
  # previous clauses from a gradual type can widen its upper bound, so
  # Phoenix.HTML.Safe.Phoenix.LiveView.Rendered.to_iodata/1 has a compiler
  # head outside `hi`). The replay records the compiler's heads to check it.
  #
  # A clause the fresh chain types as errored (the redundant path of
  # of_head/8, pattern.ex:212-219 on c24c235: its head is what is left
  # after subtracting the previous clauses, without the guard's refinement)
  # gets an unbounded `hi` (term() per position): its head without previous
  # clauses is no upper bound of the compiler's (README.md, R1:
  # Adv3.redundant/1 and the generated, warning-free Adv4.gen_red/1).
  alias ClauseMapping.Replay
  alias Module.Types.{Descr, Of, Pattern}

  @doc "The recomputed head bounds of every source clause of `def`."
  @spec heads(module(), String.t(), keyword(), tuple(), term()) :: [map()]
  def heads(module, file, attrs, {fun_arity, _kind, _meta, _clauses} = def, cache) do
    impl = Replay.impl_for(attrs)
    {_mode, {_, _, _, clauses}, expected} = Replay.default_domain(:infer, def, fun_arity, impl)
    handler = fn _meta, _fun_arity, _stack, _context -> false end

    setup = %{
      def: def,
      expected: expected,
      expected_hi: open_expected(expected, fun_arity, impl),
      stack: Module.Types.stack(:infer, file, module, fun_arity, :all, cache, handler)
    }

    {heads, _previous} =
      Enum.map_reduce(clauses, Pattern.init_previous(), &clause_head(&1, &2, setup))

    heads
  end

  defp clause_head({meta, args, guards, _body}, previous, setup) do
    stack = Replay.with_file_meta(setup.stack, meta)
    clause = {meta, args, guards}
    {lo, precise?, errored?, next} = head(setup, clause, setup.expected, previous, stack)
    {hi, _, _, _} = head(setup, clause, setup.expected_hi, Pattern.init_previous(), stack)
    hi = if errored?, do: Enum.map(hi, fn _ -> Descr.term() end), else: hi

    {%{lo: lo, hi: hi, precise: precise?, unbounded: errored?, line: Keyword.get(meta, :line)},
     next}
  end

  defp head(setup, {meta, args, guards}, expected, previous, stack) do
    {{fun, _arity}, kind, _meta, _clauses} = setup.def
    info = {{:def, kind, fun, expected}, args, guards}
    context = Module.Types.context()

    {trees, precise?, errored?, _no_previous, previous, head_context} =
      Pattern.of_head(args, guards, expected, previous, info, meta, stack, context)

    {Pattern.of_domain(trees, stack, head_context), precise?, errored?, previous}
  end

  defp open_expected([_first | rest] = expected, fun_arity, impl) do
    case impl do
      {for, callbacks} ->
        if fun_arity in callbacks,
          do: [Descr.dynamic(Of.impl(for, :open)) | rest],
          else: expected

      nil ->
        expected
    end
  end

  defp open_expected([], _fun_arity, _impl), do: []
end

defmodule ClauseMapping.Solver do
  @moduledoc false
  # Finds every assignment a: source clause -> stored clause | :drop that
  # satisfies (README.md, "Invariants"):
  #
  #   I1 partition/surjective: each stored clause gets >= 1 source clause,
  #      each source clause at most one stored clause;
  #   I2 order: stored clause k's first (minimum) source clause is smaller
  #      than stored clause k+1's;
  #   I3 drop: a(i) = :drop only if clause i is precise and some stored
  #      return is non-empty (otherwise nothing is dropped);
  #   I4 (strict variants only) a kept precise clause has a non-empty
  #      return when anything is dropped at all: if some stored return is
  #      non-empty and clause i is precise and a(i) = k, stored return k is
  #      non-empty;
  #   I5 coverage: for every stored clause k and position p, the stored
  #      argument type is a subtype of the union of the head domains of
  #      its source clauses;
  #   A1 (a1 variants only): for a(i) = k, every position p whose head
  #      domain is non-empty intersects the stored argument type.
  #
  # Variants: strict_* take the fresh-state heads (`lo`) and `precise` as
  # the compiler's; robust_* use `hi` for coverage and intersection, `lo`
  # only to decide that a position is non-empty for A1, `precise` only as
  # an upper bound of the droppable clauses, and drop I4.
  alias Module.Types.Descr

  @budget 400_000

  @variants %{
    strict_inv: %{cover: :lo, i4: true, a1: false},
    strict_a1: %{cover: :lo, i4: true, a1: true},
    robust_inv: %{cover: :hi, i4: false, a1: false},
    robust_a1: %{cover: :hi, i4: false, a1: true}
  }

  @doc "The typed variants, sorted."
  @spec variants() :: [atom()]
  def variants, do: @variants |> Map.keys() |> Enum.sort()

  @doc "Every assignment of `heads` to `stored` under `variant`, summarised."
  @spec solve([map()], [tuple()], atom()) :: map()
  def solve(heads, stored, _variant) when length(stored) > length(heads),
    do: %{class: :invariant_violation, reason: :more_stored_than_source}

  def solve(heads, stored, variant) do
    ctx = context(heads, stored, Map.fetch!(@variants, variant))
    Process.put(:cm_cover, %{})
    Process.put(:cm_nodes, 0)

    try do
      summarise(ctx, enumerate(ctx, %{}, 64))
    catch
      :budget -> %{class: :budget}
    end
  end

  defp context(heads, stored, opts) do
    n = length(heads)
    m = length(stored)

    heads =
      heads
      |> Enum.map(fn h -> Map.put(h, :h, Map.fetch!(h, opts.cover)) end)
      |> List.to_tuple()

    stored =
      stored
      |> Enum.map(fn {args, ret} -> {Enum.map(args, &Descr.upper_bound/1), ret} end)
      |> List.to_tuple()

    nonempty_fun = Enum.any?(Tuple.to_list(stored), fn {_, ret} -> not Descr.empty?(ret) end)

    droppable =
      for i <- 0..(n - 1), nonempty_fun and elem(heads, i).precise, into: MapSet.new(), do: i

    can_join =
      for k <- 0..(m - 1),
          into: %{},
          do: {k, join_mask(heads, elem(stored, k), n, nonempty_fun, opts)}

    %{n: n, m: m, heads: heads, stored: stored, droppable: droppable, can_join: can_join}
  end

  # The source clauses allowed to join a stored clause (I4, A1), as a bitmask.
  defp join_mask(heads, {args, ret}, n, nonempty_fun, opts) do
    Enum.reduce(0..(n - 1), 0, fn i, mask ->
      if can_join?(elem(heads, i), args, ret, nonempty_fun, opts),
        do: Bitwise.bor(mask, Bitwise.bsl(1, i)),
        else: mask
    end)
  end

  defp can_join?(h, args, ret, nonempty_fun, opts) do
    i4 = not opts.i4 or not (nonempty_fun and h.precise) or not Descr.empty?(ret)
    i4 and (not opts.a1 or a1_ok?(h.lo, h.h, args))
  end

  # A position known non-empty (lower head) must meet the stored type
  # through the upper head.
  defp a1_ok?(lo, hi, args) do
    Enum.zip([lo, hi, args])
    |> Enum.all?(fn {l, h, d} -> Descr.empty?(l) or not Descr.disjoint?(h, d) end)
  end

  # Collects up to `limit` solutions under `forced` (i => k | :drop).
  defp enumerate(ctx, forced, limit) do
    {sols, _} = dfs(ctx, forced, 0, 0, :erlang.make_tuple(ctx.m, 0), %{}, [], limit)
    sols
  end

  defp dfs(ctx, _forced, i, j, masks, assign, acc, limit) when i == ctx.n do
    if j == ctx.m and covers_all?(ctx, masks),
      do: {[assign | acc], limit - 1},
      else: {acc, limit}
  end

  defp dfs(ctx, forced, i, j, masks, assign, acc, limit) do
    tick()

    cond do
      limit <= 0 -> {acc, limit}
      ctx.m - j > ctx.n - i -> {acc, limit}
      not potential_ok?(ctx, forced, i, j, masks) -> {acc, limit}
      true -> branch(ctx, forced, i, j, masks, assign, acc, limit)
    end
  end

  defp branch(ctx, forced, i, j, masks, assign, acc, limit) do
    options =
      [:drop | Enum.to_list(0..min(j, ctx.m - 1)//1)]
      |> Enum.filter(&allowed?(ctx, forced, i, j, &1))

    Enum.reduce(options, {acc, limit}, fn
      _option, {acc, limit} when limit <= 0 ->
        {acc, limit}

      :drop, {acc, limit} ->
        dfs(ctx, forced, i + 1, j, masks, Map.put(assign, i, :drop), acc, limit)

      k, {acc, limit} ->
        masks = put_elem(masks, k, Bitwise.bor(elem(masks, k), Bitwise.bsl(1, i)))
        j = if k == j, do: j + 1, else: j
        dfs(ctx, forced, i + 1, j, masks, Map.put(assign, i, k), acc, limit)
    end)
  end

  defp allowed?(ctx, forced, i, j, option) do
    case Map.get(forced, i) do
      nil -> true
      ^option -> true
      _ -> false
    end and
      case option do
        :drop -> MapSet.member?(ctx.droppable, i)
        k -> k <= j and k < ctx.m and Bitwise.band(ctx.can_join[k], Bitwise.bsl(1, i)) != 0
      end
  end

  # Prune: every stored clause must still be coverable by its current
  # members plus the remaining source clauses allowed to join it.
  defp potential_ok?(ctx, forced, i, _j, masks) do
    remaining = Bitwise.bnot(Bitwise.bsl(1, i) - 1)

    Enum.all?(0..(ctx.m - 1), fn k ->
      future =
        Bitwise.band(ctx.can_join[k], remaining)
        |> exclude_forced(forced, k)

      covers?(ctx, k, Bitwise.bor(elem(masks, k), future))
    end)
  end

  defp exclude_forced(mask, forced, k) do
    Enum.reduce(forced, mask, fn
      {_i, ^k}, mask -> mask
      {i, _other}, mask -> Bitwise.band(mask, Bitwise.bnot(Bitwise.bsl(1, i)))
    end)
  end

  defp covers_all?(ctx, masks),
    do: Enum.all?(0..(ctx.m - 1), fn k -> covers?(ctx, k, elem(masks, k)) end)

  defp covers?(ctx, k, mask) do
    cache = Process.get(:cm_cover)

    case cache do
      %{{^k, ^mask} => result} ->
        result

      _ ->
        result = covered?(ctx, k, mask)
        Process.put(:cm_cover, Map.put(cache, {k, mask}, result))
        result
    end
  end

  # I5: every stored argument type is inside the union of the members' heads.
  defp covered?(ctx, k, mask) do
    {args, _ret} = elem(ctx.stored, k)
    members = for i <- 0..(ctx.n - 1), Bitwise.band(mask, Bitwise.bsl(1, i)) != 0, do: i

    members != [] and
      args
      |> Enum.with_index()
      |> Enum.all?(fn {d, p} -> Descr.subtype?(d, members_union(ctx, members, p)) end)
  end

  defp members_union(ctx, members, p) do
    Enum.reduce(members, Descr.none(), fn i, acc ->
      Descr.opt_union(acc, Enum.at(elem(ctx.heads, i).h, p))
    end)
  end

  defp tick do
    nodes = Process.get(:cm_nodes) + 1
    Process.put(:cm_nodes, nodes)
    if nodes > @budget, do: throw(:budget)
  end

  defp summarise(_ctx, []), do: %{class: :no_solution}

  defp summarise(ctx, [only]) do
    %{class: :unique, solutions: 1, assignment: only, per_stored: per_stored(ctx, [only])}
    |> add_exactness(ctx, [only])
  end

  defp summarise(ctx, sols) do
    # Every (clause, option) seen in a solution is possible; for the rest,
    # ask whether a solution exists with that option forced.
    seen = for s <- sols, {i, o} <- s, into: MapSet.new(), do: {i, o}

    extra =
      for i <- 0..(ctx.n - 1),
          o <- [:drop | Enum.to_list(0..(ctx.m - 1))],
          not MapSet.member?(seen, {i, o}),
          static_possible?(ctx, i, o),
          sol = enumerate(ctx, %{i => o}, 1),
          sol != [],
          do: hd(sol)

    all = sols ++ extra

    %{class: :multiple, solutions: length(sols), per_stored: per_stored(ctx, all)}
    |> add_exactness(ctx, all)
  end

  defp members_of(solution, k), do: Enum.sort(for {i, ^k} <- solution, do: i)

  defp static_possible?(ctx, i, :drop), do: MapSet.member?(ctx.droppable, i)
  defp static_possible?(ctx, i, k), do: Bitwise.band(ctx.can_join[k], Bitwise.bsl(1, i)) != 0

  # must: in every solution; may: in some solution (over the witnesses
  # collected, which include one witness for every possible pair).
  defp per_stored(ctx, sols) do
    for k <- 0..(ctx.m - 1) do
      sets = Enum.map(sols, &members_of(&1, k))
      may = sets |> Enum.concat() |> Enum.uniq() |> Enum.sort()
      must = Enum.reduce(sets, may, fn set, acc -> Enum.filter(acc, &(&1 in set)) end)
      %{may: may, must: must}
    end
  end

  defp add_exactness(result, ctx, sols) do
    # A witness set gives exact "may" sets; "must" needs all solutions, so
    # exactness is only claimed from a stored clause's may == must when the
    # may set was derived from witnesses for every possible pair (above).
    dropped_sets = Enum.map(sols, fn s -> Enum.sort(for {i, :drop} <- s, do: i) end)
    may_drop = dropped_sets |> Enum.concat() |> Enum.uniq() |> Enum.sort()

    per =
      Enum.map(result.per_stored, fn %{may: may, must: must} = entry ->
        Map.merge(entry, %{exact: may == must, anchor_exact: anchor_exact?(may, must)})
      end)

    _ = ctx
    Map.merge(result, %{per_stored: per, may_drop: may_drop})
  end

  defp anchor_exact?([], _must), do: false
  defp anchor_exact?([first | _], must), do: first in must
end

defmodule ClauseMapping.Analyze do
  @moduledoc false
  alias ClauseMapping.{Heads, Replay, Solver}
  alias Module.Types.Descr

  # One module: returns a list of function records. `passes` is an ordered
  # list of {name, modules}: the modules the replay's checker cache knows
  # (at compile time the cache holds the dependencies and whatever project
  # modules were compiled before; that set is not recorded). Passes run in
  # order until every stored signature of the module is reproduced.
  @doc "The function records of the module at `path`."
  @spec module(Path.t(), keyword()) :: [map()]
  def module(path, passes) do
    {:ok, beam} = SpecLint.Beam.read(path)

    with {:ok, %{exports: exports}} <- beam.exck,
         {:ok, info} <- beam.debug_info do
      attrs = info.checker_attributes
      defs = info.definitions
      file = info.file || "nofile"

      targets =
        for {fa, :def, _, _} <- defs,
            %{sig: {:infer, _, _} = sig} <- [Map.get(exports, fa)],
            do: {fa, sig}

      replay =
        if Replay.protocol?(attrs),
          do: %{},
          else: replay(beam.module, file, attrs, defs, passes, targets)

      for {{_name, _arity} = fa, kind, meta, clauses} = def <- defs,
          kind == :def,
          %{sig: sig} <- [Map.get(exports, fa)],
          do: function(beam.module, file, attrs, def, sig, replay, meta, clauses)
    else
      {:error, reason} -> [%{module: inspect(beam.module), error: inspect(reason)}]
    end
  end

  defp replay(module, file, attrs, defs, passes, targets) do
    Enum.reduce_while(passes, %{}, fn {name, cache}, acc ->
      result = run_replay(module, file, attrs, defs, cache)
      acc = Map.put(acc, name, result)

      done =
        match?({:ok, _}, result) and
          Enum.all?(targets, fn {fa, sig} -> Enum.any?(acc, &reproduces?(&1, fa, sig)) end)

      if done, do: {:halt, acc}, else: {:cont, acc}
    end)
    |> Enum.sort_by(fn {name, _} -> Enum.find_index(passes, &(elem(&1, 0) == name)) end)
  end

  defp reproduces?({_pass, {:ok, {types, _table}}}, fa, sig) do
    case Map.fetch(types, fa) do
      {:ok, inferred} ->
        {grouped, _} = Replay.group_by_return_tracked(inferred)
        compare(grouped, sig) != :differs

      :error ->
        false
    end
  end

  defp reproduces?(_pass, _fa, _sig), do: false

  # `cache` is a checker cache shared by every module of the run for this
  # pass (built once by ClauseMapping.CLI.build_cache/1; replays in :infer
  # mode only read it).
  defp run_replay(module, file, attrs, defs, cache) do
    task =
      Task.async(fn ->
        try do
          {:ok, Replay.run(module, file, attrs, defs, cache)}
        rescue
          e -> {:error, Exception.format_banner(:error, e) |> String.slice(0, 300)}
        catch
          kind, reason -> {:error, inspect({kind, reason}) |> String.slice(0, 300)}
        end
      end)

    case Task.yield(task, 120_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
    end
  end

  defp function(module, file, attrs, {fa, _kind, meta, clauses} = def, sig, replay, _meta, _) do
    {name, arity} = fa
    lines = Enum.map(clauses, fn {m, _, _, _} -> Keyword.get(m, :line) end)

    base = %{
      module: inspect(module),
      name: name,
      arity: arity,
      line: Keyword.get(meta, :line),
      generated: Keyword.get(meta, :generated, false),
      n_source: length(clauses),
      source_lines: lines
    }

    case sig do
      {:infer, _domain, stored} ->
        a = mode_a(module, file, attrs, def, stored)
        replay = replay_result(replay, fa, sig)
        {heads_raw, a} = Map.pop(a, :heads_raw)
        replay = replay |> head_checks(heads_raw) |> Map.delete(:heads_raw)

        base
        |> Map.put(:m_stored, length(stored))
        |> Map.merge(a)
        |> Map.put(:replay, replay)

      other ->
        r = %{class: :no_infer_signature, sig: sig_kind(other)}
        Map.merge(base, %{m_stored: nil, modes: all_modes(r), replay: nil})
    end
  end

  defp head_checks(%{heads_raw: compiler} = replay, [_ | _] = ours) when is_list(compiler) do
    replay
    |> Map.put(:heads_lo_equal, heads_lo_equal?(ours, compiler))
    |> Map.put(:heads_bracketed, heads_bracketed?(ours, compiler))
  end

  defp head_checks(replay, _ours), do: replay

  defp sig_kind({kind, _, _}), do: kind
  defp sig_kind(other), do: other

  # The structural classes are decided from the clause counts and the
  # {:super, ...} shape alone (README.md, "Invariants"); the typed variants
  # run only on the rest. Heads are still recomputed for an identity (for
  # the head checks against the replay), but never decide it: a typed
  # solve could only lose it (review finding R3, Adv7.ident/1).
  defp mode_a(module, file, attrs, {_fa, _kind, _meta, clauses} = def, stored) do
    n = length(clauses)
    m = length(stored)

    case structural(clauses, n, m) do
      {:done, r} ->
        %{modes: all_modes(r)}

      {:identity, r} ->
        with_heads(module, file, attrs, def, fn _heads -> all_modes(r) end, all_modes(r))

      :typed ->
        solve = fn heads ->
          Map.new(Solver.variants(), &{&1, classify(Solver.solve(heads, stored, &1), n, m)})
        end

        with_heads(module, file, attrs, def, solve, nil)
    end
  end

  defp structural([{_, _, [], {:super, _, [_ | _]}}], _n, m),
    do:
      {:done, %{class: :super_derived, per_stored: exact_per(List.duplicate(0, m)), may_drop: []}}

  defp structural(_clauses, 1, 1),
    do: {:done, %{class: :trivial_single, per_stored: exact_per([0]), may_drop: []}}

  defp structural(_clauses, 1, _m),
    do: {:done, %{class: :invariant_violation, reason: :more_stored_than_source}}

  defp structural(_clauses, n, n),
    do:
      {:identity,
       %{class: :identity, per_stored: exact_per(Enum.to_list(0..(n - 1))), may_drop: []}}

  defp structural(_clauses, _n, _m), do: :typed

  defp exact_per(indexes),
    do: for(i <- indexes, do: %{may: [i], must: [i], exact: true, anchor_exact: true})

  # Recomputes the heads and applies `modes_fun`; a failure gives `fallback`
  # (or unsupported when there is none).
  defp with_heads(module, file, attrs, def, modes_fun, fallback) do
    cache = cache_for_heads()

    try do
      heads = Heads.heads(module, file, attrs, def, cache)

      %{
        modes: modes_fun.(heads),
        heads: Enum.map(heads, &Map.take(&1, [:precise, :unbounded, :line])),
        heads_raw: Enum.map(heads, &{&1.lo, &1.hi})
      }
    rescue
      e ->
        reason = Exception.format_banner(:error, e) |> String.slice(0, 200)
        %{modes: fallback || all_modes(%{class: :unsupported, reason: reason})}
    after
      Module.ParallelChecker.stop(cache)
    end
  end

  defp all_modes(r), do: Map.new(Solver.variants(), &{&1, r})

  defp cache_for_heads do
    {:ok, cache} = Module.ParallelChecker.start_link([])
    cache
  end

  defp classify(%{class: :unique} = r, n, m) do
    Map.put(r, :class, if(n == m, do: :identity, else: :solved))
  end

  defp classify(%{class: :multiple} = r, _n, _m) do
    if Enum.all?(r.per_stored, & &1.exact),
      do: Map.put(r, :class, :solved_multi),
      else: Map.put(r, :class, :ambiguous)
  end

  defp classify(r, _n, _m), do: r

  defp replay_result(replay, _fa, _sig) when replay == %{} or replay == [],
    do: %{status: :protocol}

  defp replay_result(replay, fa, sig) do
    results = for {pass, result} <- replay, do: pass_result(pass, result, fa, sig)

    case Enum.find(results, fn {_, status, _} -> status in [:term_equal, :semantic_equal] end) do
      {pass, status, mapping} ->
        Map.merge(%{status: status, pass: pass}, mapping)

      nil ->
        %{status: :not_reproduced, passes: Enum.map(results, fn {p, s, _} -> {p, inspect(s)} end)}
    end
  end

  defp pass_result(pass, {:ok, {types, table}}, fa, sig) do
    case Map.fetch(types, fa) do
      {:ok, inferred} ->
        {grouped, groups} = Replay.group_by_return_tracked(inferred)
        {pass, compare(grouped, sig), mapping(Map.get(table, fa), groups)}

      :error ->
        {pass, :missing, nil}
    end
  end

  defp pass_result(pass, {:error, reason}, _fa, _sig), do: {pass, {:error, reason}, nil}

  defp mapping(%{handler: :infer, clauses: clauses, mapping: mapping}, groups) do
    # mapping: [{source_index, inferred_index}]; groups: stored -> [inferred_index]
    members =
      Enum.map(groups, fn inferred_indexes ->
        for {s, t} <- mapping, t in inferred_indexes, do: s
      end)
      |> Enum.map(&Enum.sort/1)

    kept = for {s, _} <- mapping, do: s
    dropped = Enum.to_list(0..(length(clauses) - 1)) -- kept

    a1_violations =
      for {c, i} <- Enum.with_index(clauses),
          {a, h} <- Enum.zip(c.args, c.head),
          Descr.empty?(a) and not Descr.empty?(h),
          uniq: true,
          do: i

    %{
      handler: :infer,
      heads_raw: Enum.map(clauses, & &1.head),
      members: members,
      dropped: Enum.sort(dropped),
      a1_violations: a1_violations,
      precise: Enum.map(clauses, & &1.precise),
      empty_return: Enum.map(clauses, &Descr.empty?(&1.return))
    }
  end

  defp mapping(%{handler: :super} = info, groups),
    do: %{
      handler: :super,
      super: inspect(info.super),
      members: Enum.map(groups, fn _ -> [0] end),
      dropped: []
    }

  defp mapping(other, _groups), do: %{handler: inspect(other)}

  # E1/E2 check against the compiler's own head domains (recorded by the
  # replay): lo == compiler (the fresh-state recomputation is exact), and
  # lo <= compiler <= hi (the bounds the robust variants rely on).
  defp heads_lo_equal?(ours, compiler) do
    length(ours) == length(compiler) and
      Enum.all?(Enum.zip(ours, compiler), fn {{lo, _hi}, c} ->
        Enum.all?(Enum.zip(lo, c), fn {p, q} -> Descr.equal?(p, q) end)
      end)
  end

  defp heads_bracketed?(ours, compiler) do
    length(ours) == length(compiler) and
      Enum.all?(Enum.zip(ours, compiler), fn {{lo, hi}, c} ->
        Enum.all?(Enum.zip([lo, c, hi]), fn {l, x, h} ->
          Descr.subtype?(l, x) and Descr.subtype?(x, h)
        end)
      end)
  end

  defp compare(grouped, sig) do
    cond do
      grouped == sig -> :term_equal
      semantic_equal?(grouped, sig) -> :semantic_equal
      true -> :differs
    end
  end

  defp semantic_equal?({:infer, d1, c1}, {:infer, d2, c2}) do
    length(c1) == length(c2) and domain_equal?(d1, d2) and
      Enum.all?(Enum.zip(c1, c2), fn {{a1, r1}, {a2, r2}} ->
        length(a1) == length(a2) and Descr.equal?(r1, r2) and
          Enum.all?(Enum.zip(a1, a2), fn {x, y} -> Descr.equal?(x, y) end)
      end)
  end

  defp semantic_equal?(_, _), do: false

  defp domain_equal?(nil, nil), do: true

  defp domain_equal?(d1, d2) when is_list(d1) and is_list(d2),
    do:
      length(d1) == length(d2) and
        Enum.all?(Enum.zip(d1, d2), fn {x, y} -> Descr.equal?(x, y) end)

  defp domain_equal?(_, _), do: false
end

defmodule ClauseMapping.CLI do
  @moduledoc false
  alias ClauseMapping.Analyze

  @doc "Runs the fixtures or one corpus (see the header)."
  @spec main([String.t()]) :: :ok
  def main(["fixtures", out]) do
    require_c24c235!()

    dir =
      Path.join(
        System.tmp_dir!(),
        "clause_mapping_fixtures_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    Code.put_compiler_option(:debug_info, true)
    src = Path.join(__DIR__, "fixtures.ex")

    {:ok, modules, _warnings} =
      Kernel.ParallelCompiler.compile_to_path([src], dir, return_diagnostics: true)

    Code.prepend_path(dir)
    passes = [deps: build_cache(modules), all: build_cache(modules ++ stdlib_modules())]
    expected = ClauseMappingFixtures.Expected

    {rows, records} =
      [{ClauseMappingFixtures, expected.expected()} | Enum.sort(expected.adversarial())]
      |> Enum.map(&fixture_module(&1, dir, passes))
      |> Enum.unzip()

    rows = Enum.concat(rows)
    write(out, %{label: "fixtures", rows: rows, records: Enum.concat(records)})
    print_fixture_table(rows)
  end

  def main(["corpus" | args]) do
    require_c24c235!()

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [label: :string, ebin: :keep, code_path: :keep, out: :string, focus: :keep]
      )

    ebins = Keyword.get_values(opts, :ebin)
    for p <- Keyword.get_values(opts, :code_path), do: Code.append_path(p)
    for e <- ebins, do: Code.append_path(e)

    beams = Enum.flat_map(ebins, fn e -> Path.wildcard(Path.join(e, "*.beam")) end) |> Enum.sort()

    project_modules = modules_in(ebins)
    dep_modules = modules_in(Keyword.get_values(opts, :code_path))

    passes =
      Enum.map(
        [
          deps: project_modules ++ dep_modules,
          all: project_modules ++ dep_modules ++ stdlib_modules(),
          project: project_modules,
          empty: []
        ],
        fn {name, mods} -> {name, build_cache(mods)} end
      )

    records =
      beams
      |> Task.async_stream(fn b -> safe_module(b, passes) end,
        timeout: :infinity,
        max_concurrency: System.schedulers_online(),
        ordered: true
      )
      |> Enum.flat_map(fn {:ok, r} -> r end)

    focus = Keyword.get_values(opts, :focus)
    summary = summarise(records)
    focus_rows = Enum.map(focus, &focus_row(&1, records))

    write(opts[:out], %{
      label: opts[:label],
      summary: summary,
      focus: focus_rows,
      records: records
    })

    IO.puts(JSON.encode!(%{label: opts[:label], summary: summary, focus: focus_rows}))
    :ok
  end

  # The replay copies c24c235's Module.Types orchestration; any other
  # compiler (or a modified c24c235 build, which preflight's identity check
  # rejects) would give meaningless results with exit 0.
  defp require_c24c235! do
    case SpecLint.Compiler.preflight() do
      {:ok, %{adapter: SpecLint.Compiler.V121, adapter_id: "1.21.0-dev+c24c235"}} ->
        :ok

      other ->
        IO.puts(
          :stderr,
          "clause_mapping: needs the qualified Elixir c24c235 build, got " <>
            "#{System.version()} (#{inspect(other, limit: 5)})"
        )

        System.halt(2)
    end
  end

  defp fixture_module({module, expected}, dir, passes) do
    path = Path.join(dir, "#{module}.beam")
    records = Analyze.module(path, passes)
    {:ok, %{debug_info: {:ok, info}}} = SpecLint.Beam.read(path)
    macros = for {fa, :defmacro, _, _} <- info.definitions, do: fa

    rows =
      for {fa, exp} <- Enum.sort(expected) do
        rec = Enum.find(records, &({&1.name, &1.arity} == fa))
        fixture_row({module, fa}, exp, rec, fa in macros)
      end

    {rows, records}
  end

  # A checker cache that knows `modules` (read from their object code on the
  # code path), as the compile-time cache knew the modules compiled before.
  @doc false
  @spec build_cache([module()]) :: pid()
  def build_cache(modules) do
    {:ok, cache} = Module.ParallelChecker.start_link([])

    for m <- Enum.uniq(modules),
        do: Module.ParallelChecker.fetch_export(cache, m, :module_info, 0, true)

    cache
  end

  defp modules_in(dirs) do
    for d <- dirs,
        b <- Path.wildcard(Path.join(d, "*.beam")),
        do: b |> Path.basename(".beam") |> String.to_atom()
  end

  defp stdlib_modules do
    for app <- [:elixir, :eex, :ex_unit, :iex, :logger, :mix],
        dir = :code.lib_dir(app),
        is_list(dir),
        m <- modules_in([Path.join(List.to_string(dir), "ebin")]),
        do: m
  end

  # Each module runs in its own task with a wall-clock limit; a module that
  # exceeds it is recorded as an error (unsupported), never dropped.
  @module_timeout 600_000

  defp safe_module(beam, passes) do
    if System.get_env("CM_TRACE"), do: IO.puts(:stderr, "start #{Path.basename(beam)}")
    started = System.monotonic_time(:millisecond)

    task =
      Task.async(fn ->
        try do
          Analyze.module(beam, passes)
        rescue
          e ->
            [%{module: beam, error: Exception.format_banner(:error, e) |> String.slice(0, 300)}]
        end
      end)

    result =
      case Task.yield(task, @module_timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        nil -> [%{module: beam, error: "timeout"}]
      end

    if System.get_env("CM_TRACE"),
      do:
        IO.puts(
          :stderr,
          "done #{Path.basename(beam)} #{System.monotonic_time(:millisecond) - started}ms"
        )

    result
  end

  defp fixture_row(fa, :not_stored, rec, macro?) do
    %{fun: fmt(fa), expected: "not_stored", stored: rec != nil, pass: rec == nil and macro?}
  end

  defp fixture_row(fa, {:super, _}, rec, _) do
    replay = rec.replay
    modes = Map.new(rec.modes, fn {v, r} -> {v, r.class} end)

    %{
      fun: fmt(fa),
      expected: "super: every stored clause -> [0]",
      m_stored: rec.m_stored,
      modes: modes,
      replay: replay[:status],
      pass:
        Enum.all?(rec.modes, fn {_, r} ->
          r.class == :super_derived and Enum.all?(r.per_stored, &(&1.must == [0]))
        end) and replay[:members] == Enum.map(1..rec.m_stored, fn _ -> [0] end)
    }
  end

  defp fixture_row(fa, {:stored, members, dropped}, rec, _) do
    replay_ok = rec.replay[:members] == members and rec.replay[:dropped] == dropped

    %{
      fun: fmt(fa),
      expected: %{members: members, dropped: dropped},
      actual_stored_count: rec.m_stored,
      replay: %{
        status: rec.replay[:status],
        members: rec.replay[:members],
        dropped: rec.replay[:dropped],
        agrees_with_expected: replay_ok,
        heads_lo_equal: rec.replay[:heads_lo_equal],
        heads_bracketed: rec.replay[:heads_bracketed]
      },
      modes: Map.new(rec.modes, fn {v, r} -> {v, judge(r, members, dropped)} end)
    }
  end

  # For a mode A result: exact stored clauses must equal the expectation
  # (a wrong exact claim is an error); ambiguous ones must bracket it
  # (must <= expected <= may: a sound over-approximation).
  defp judge(%{per_stored: per} = r, members, dropped) when length(per) == length(members) do
    checks =
      Enum.zip(per, members)
      |> Enum.map(fn {%{may: may, must: must, exact: exact} = c, exp} ->
        sound = Enum.all?(must, &(&1 in exp)) and Enum.all?(exp, &(&1 in may))

        %{
          exact: exact,
          anchor_exact: c.anchor_exact,
          correct: if(exact, do: must == exp, else: sound),
          may: may,
          must: must
        }
      end)

    drop_sound = Enum.all?(dropped, &(&1 in Map.get(r, :may_drop, [])))

    %{
      class: r.class,
      exact_clauses: Enum.count(checks, & &1.exact),
      anchor_exact_clauses: Enum.count(checks, & &1.anchor_exact),
      clauses: length(checks),
      wrong: Enum.count(checks, &(not &1.correct)) + if(drop_sound, do: 0, else: 1),
      per_stored: checks
    }
  end

  defp judge(r, members, _dropped),
    do: %{
      class: r.class,
      clauses: length(members),
      exact_clauses: 0,
      anchor_exact_clauses: 0,
      wrong: if(r.class in [:unsupported, :budget, :no_solution], do: 0, else: 1)
    }

  defp print_fixture_table(rows) do
    Enum.each(rows, &IO.puts(fixture_line(&1)))

    Enum.each(ClauseMapping.Solver.variants(), fn v ->
      wrong = Enum.sum_by(rows, &row_wrong(&1, v))
      IO.puts("#{v}: #{wrong} wrong exact claims or unsound brackets over the fixtures")
    end)
  end

  defp row_wrong(%{modes: %{} = modes}, v) do
    case modes[v] do
      %{wrong: wrong} -> wrong
      _class -> 0
    end
  end

  defp row_wrong(_row, _v), do: 0

  defp fixture_line(%{modes: %{} = modes, replay: %{} = rp} = row) do
    cols =
      Enum.map_join(ClauseMapping.Solver.variants(), " ", fn v ->
        m = modes[v]
        "#{v}=#{m.class}:#{m.exact_clauses}/#{m.clauses}:wrong#{m.wrong}"
      end)

    "#{String.pad_trailing(row.fun, 26)} stored=#{row.actual_stored_count} " <>
      "replay=#{rp.status}/#{rp.agrees_with_expected} #{cols}"
  end

  defp fixture_line(other), do: inspect(other)

  defp focus_row(spec, records) do
    [mod, fa] = String.split(spec, ~r/\.(?=[^.]+\/\d+$)/)
    [name, arity] = String.split(fa, "/")

    case Enum.find(
           records,
           &(Map.get(&1, :module) == mod and to_string(Map.get(&1, :name)) == name and
               Map.get(&1, :arity) == String.to_integer(arity))
         ) do
      nil -> %{focus: spec, found: false}
      rec -> %{focus: spec, found: true, record: rec}
    end
  end

  defp summarise(records) do
    fun_records = Enum.filter(records, &Map.has_key?(&1, :modes))
    inferred = Enum.filter(fun_records, &(&1.m_stored != nil))

    per_variant =
      Map.new(ClauseMapping.Solver.variants(), fn v ->
        {v,
         %{
           # README.md, E1-E3 and R1-R2: the typed variants' exact claims
           # rest on head recomputations the compiler does not guarantee.
           exact_claims: :unverified,
           by_class: frequencies(inferred, & &1.modes[v].class),
           stored_clauses_exact: exact_count(inferred, v, :exact),
           stored_clauses_anchor_exact: exact_count(inferred, v, :anchor_exact),
           replay_check: replay_check(inferred, v)
         }}
      end)

    %{
      modules_with_errors: Enum.count(records, &Map.has_key?(&1, :error)),
      functions: length(fun_records),
      functions_with_infer_signature: length(inferred),
      stored_clauses: Enum.sum_by(inferred, & &1.m_stored),
      nontrivial_functions: Enum.count(inferred, &nontrivial?/1),
      nontrivial_stored_clauses:
        inferred |> Enum.filter(&nontrivial?/1) |> Enum.sum_by(& &1.m_stored),
      replay: frequencies(inferred, & &1.replay[:status]),
      heads_lo_equal: frequencies(inferred, & &1.replay[:heads_lo_equal]),
      heads_bracketed: frequencies(inferred, & &1.replay[:heads_bracketed]),
      a1_violating_functions:
        Enum.count(inferred, &(Map.get(&1.replay || %{}, :a1_violations, []) != [])),
      structural: structural_check(Enum.reject(inferred, &nontrivial?/1)),
      variants: per_variant
    }
  end

  # Functions whose mapping is not decided by I1/I2 alone: more than one
  # source clause and fewer stored clauses (a {:super, ...} clause is a
  # single source clause). From the clause counts only, never from a solve.
  defp nontrivial?(r), do: r.n_source > 1 and r.m_stored < r.n_source

  # The adopted structural classes against the replay oracle.
  defp structural_check(recs) do
    checked =
      for %{replay: %{status: s, members: members}} = r <- recs,
          s in [:term_equal, :semantic_equal],
          %{per_stored: per} <- [r.modes.robust_inv],
          do: Enum.map(per, & &1.must) == members

    %{
      functions: length(recs),
      stored_clauses: Enum.sum_by(recs, & &1.m_stored),
      replay_checked: length(checked),
      agree: Enum.count(checked, & &1),
      wrong: Enum.count(checked, &(not &1))
    }
  end

  defp exact_count(recs, variant, key) do
    Enum.sum_by(recs, fn r ->
      case r.modes[variant] do
        %{per_stored: per} -> Enum.count(per, &Map.get(&1, key))
        _ -> 0
      end
    end)
  end

  # Mode A against the replay oracle, where the replay reproduced the
  # stored signature: an exact claim that differs from the replay is wrong;
  # an ambiguous clause whose must/may sets do not bracket the replay is
  # unsound; no_solution means a constraint excluded the compiler's own
  # assignment.
  defp replay_check(recs, variant) do
    zero = %{
      functions: 0,
      exact_agree: 0,
      exact_wrong: 0,
      ambiguous_sound: 0,
      ambiguous_unsound: 0,
      no_solution: 0
    }

    Enum.reduce(recs, zero, fn r, acc -> check_record(r.replay, r.modes[variant], acc) end)
  end

  defp check_record(%{status: s, members: members}, %{per_stored: per}, acc)
       when s in [:term_equal, :semantic_equal] and length(per) == length(members) do
    per
    |> Enum.zip(members)
    |> Enum.reduce(%{acc | functions: acc.functions + 1}, fn {entry, expected}, acc ->
      key = verdict(entry, expected)
      Map.update!(acc, key, &(&1 + 1))
    end)
  end

  defp check_record(%{status: s}, %{class: :no_solution}, acc)
       when s in [:term_equal, :semantic_equal],
       do: %{acc | functions: acc.functions + 1, no_solution: acc.no_solution + 1}

  defp check_record(_replay, _mode, acc), do: acc

  defp verdict(%{exact: true, must: must}, expected) when must == expected, do: :exact_agree
  defp verdict(%{exact: true}, _expected), do: :exact_wrong

  defp verdict(%{may: may, must: must}, expected) do
    if Enum.all?(must, &(&1 in expected)) and Enum.all?(expected, &(&1 in may)),
      do: :ambiguous_sound,
      else: :ambiguous_unsound
  end

  defp frequencies(recs, fun),
    do: recs |> Enum.map(fun) |> Enum.frequencies() |> Map.new(fn {k, v} -> {inspect(k), v} end)

  defp fmt({ClauseMappingFixtures, {n, a}}), do: "#{n}/#{a}"

  defp fmt({module, {n, a}}),
    do: "#{module |> inspect() |> String.replace_prefix("ClauseMappingFixtures.", "")}.#{n}/#{a}"

  defp write(nil, _), do: :ok

  defp write(path, data) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(jsonable(data)))
  end

  defp jsonable(%{__struct__: _} = s), do: inspect(s)
  defp jsonable(map) when is_map(map), do: Map.new(map, fn {k, v} -> {jkey(k), jsonable(v)} end)
  defp jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  defp jsonable(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> Enum.map(&jsonable/1)

  defp jsonable(atom) when is_atom(atom) and atom not in [nil, true, false],
    do: Atom.to_string(atom)

  defp jsonable(other), do: other

  defp jkey(k) when is_binary(k), do: k
  defp jkey(k) when is_atom(k), do: Atom.to_string(k)
  defp jkey(k), do: inspect(k)
end

ClauseMapping.CLI.main(System.argv())
