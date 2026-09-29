defmodule SpecLint.Compiler.DescrWalk do
  @moduledoc """
  The walk over `Module.Types.Descr` terms that the adapters share:
  `components/2`, the printer (`to_string/2`) and the canonical form
  (`canonical/2`).

  It reads the part of the layout that is the same on every qualified
  compiler line, each adapter probing it at preflight (`:descr_encoding`):
  a descr is `:term` or a map of per-kind parts (`bitmap`, `atom`, `tuple`,
  `map`, `list`, `fun`, `dynamic`); the bitmap bits; atoms as
  `{:union | :negation, :sets}`; tuples, maps and non-empty lists as BDDs
  whose `bdd_to_dnf/1` lines hold literals `{hash, tag_or_head,
  elements_or_tail}`; `fun()` as `{:negation, %{}}`.

  Everything that differs between compiler lines goes through the adapter
  passed as `ops`, which implements this behaviour and the set operations
  of `SpecLint.Compiler` (`union/2`, `intersection/2`, `difference/2`):
  how `term()` and recursive nodes are expanded (`expand/1`), how a map
  literal's fields and key domains are encoded (`map_view/1`), and whether
  a term is a recursive node (`recursive_node?/1`).
  """

  import Bitwise

  alias Module.Types.Descr

  @doc """
  `descr` with `term()` and a recursive node at the top expanded into the
  map of per-kind parts. Every other type is returned unchanged.
  """
  @callback expand(SpecLint.Compiler.descr()) :: map()

  @doc """
  The view of one map literal `{hash, tag, fields}` of a `bdd_to_dnf/1`
  line, other than the open map with no fields (which is `{:whole, :map}`).
  """
  @callback map_view(tuple()) :: SpecLint.Compiler.view()

  @doc """
  Whether `term` is a recursive type node (always `false` on a compiler
  line without recursive nodes). `expand/1` unfolds a node one level.
  """
  @callback recursive_node?(term()) :: boolean()

  # Bits of the descr bitmap, read by components/2 and probed at preflight.
  @bit_kinds [
    binary: 0b1,
    bitstring_no_binary: 0b10,
    integer: 0b1000,
    float: 0b10000,
    pid: 0b100000,
    port: 0b1000000,
    reference: 0b10000000
  ]
  @bit_empty_list 0b100

  @typedoc "A kind stored as one bit of the descr bitmap."
  @type bit_kind :: :binary | :bitstring_no_binary | :integer | :float | :pid | :port | :reference

  @doc "The bitmap bit of every bit kind, as the adapters probe them."
  @spec bit_kinds() :: [{bit_kind(), 1 | 2 | 8 | 16 | 32 | 64 | 128}, ...]
  def bit_kinds, do: @bit_kinds

  @doc "The bitmap bit of the empty list."
  @spec bit_empty_list() :: 4
  def bit_empty_list, do: @bit_empty_list

  ## Printing
  #
  # Printing is presentation only, but it must be readable and must not
  # depend on how a type was built. Descr keeps differences lazily, so
  # `term() − (A ∪ B ∪ C)` prints as `not (A and not B and not C) and not (B
  # and not C) and not C` (Phase 0 bug O4). Static types are printed from
  # their normal form instead: tuple and map parts line by line from their
  # DNF, each line as its positive literals and its live negative literals
  # (negatives disjoint from the positives are dropped); the other kinds
  # through Descr. The complement is printed the same way, and `not (...)`
  # of it is used when it is shorter. An empty type prints as `none()`
  # (a lazy difference that is empty would otherwise print as a non-empty
  # looking `A and not B`). Gradual types print through Descr.
  #
  # Decision (Milestone 1): the complement is no longer printed in full
  # unconditionally, but the result is the same string as before for
  # every type. (1) Tuple and map literals are printed once per call and
  # memoised: the complement's lines negate the literals the direct form
  # already printed, which for struct types was most of the cost. (2) The
  # complement is printed piece by piece with a budget, the length of the
  # direct form minus `not `: a running lower bound of its length (the
  # distinct pieces so far plus their ` or ` separators, never counting
  # parentheses) that reaches the budget proves `not (...)` cannot be
  # shorter, and printing stops. No length threshold or structural guess
  # decides the form, because neither was exact on the corpora (a
  # 23-character `not map() and not {...}` loses to `not ({...} or map())`,
  # and a positive union without `not` can lose to its complement).

  @doc "The presentation string of `descr` (`c:SpecLint.Compiler.to_string/1`)."
  @spec to_string(module(), SpecLint.Compiler.descr()) :: String.t()
  def to_string(ops, descr) do
    cond do
      Descr.empty?(descr) -> "none()"
      Descr.gradual?(descr) -> quoted(descr)
      true -> canonical_or_complement(ops, descr)
    end
  end

  defp quoted(descr), do: Descr.to_quoted_string(descr, skip_dynamic_for_indivisible: false)

  defp canonical_or_complement(ops, descr) do
    complement = ops.difference(Descr.term(), descr)

    if Descr.empty?(complement) do
      "term()"
    else
      {:ok, direct, memo} = normal_form_string(ops, descr, :infinity, %{})
      direct_length = String.length(direct)

      ops
      |> normal_form_string(complement, direct_length - String.length("not "), memo)
      |> shorter(direct, direct_length)
    end
  end

  defp shorter({:ok, complement, _memo}, direct, direct_length) do
    negated = "not " <> parenthesise(complement)
    if String.length(negated) < direct_length, do: negated, else: direct
  end

  defp shorter(:over_budget, direct, _direct_length), do: direct

  # The normal form string of a static type, or `:over_budget` as soon as
  # a lower bound of its length reaches `budget`. `memo` maps `{kind,
  # literal}` to its printed string.
  defp normal_form_string(ops, descr, budget, memo) do
    static = ops.expand(descr)
    rest = Map.drop(static, [:tuple, :map])

    first = if Descr.empty?(rest), do: [], else: [quoted(rest)]

    acc = %{
      pieces: first,
      seen: MapSet.new(),
      bound: pieces_bound(first),
      memo: memo
    }

    lines =
      Enum.flat_map([:tuple, :map], fn kind ->
        case Map.get(static, kind) do
          nil -> []
          bdd -> bdd |> Descr.bdd_to_dnf() |> Enum.reverse() |> Enum.map(&{kind, &1})
        end
      end)

    with {:ok, acc} <- within_budget(acc, budget),
         {:ok, acc} <- add_lines(ops, lines, acc, budget) do
      string =
        case Enum.reverse(acc.pieces) do
          [single] -> single
          pieces -> Enum.map_join(pieces, " or ", &parenthesise_and/1)
        end

      {:ok, string, acc.memo}
    end
  end

  defp add_lines(_ops, [], acc, _budget), do: {:ok, acc}

  defp add_lines(ops, [{kind, dnf_line} | lines], acc, budget) do
    {printed, memo} = line(ops, kind, dnf_line, acc.memo)
    acc = %{acc | memo: memo}

    acc = Enum.reduce(printed, acc, &add_piece/2)
    with {:ok, acc} <- within_budget(acc, budget), do: add_lines(ops, lines, acc, budget)
  end

  # Repeated lines are printed once (the first occurrence is kept); the
  # bound counts each distinct piece and the ` or ` before it.
  defp add_piece(string, acc) do
    if MapSet.member?(acc.seen, string) do
      acc
    else
      separator = if acc.pieces == [], do: 0, else: String.length(" or ")

      %{
        acc
        | pieces: [string | acc.pieces],
          seen: MapSet.put(acc.seen, string),
          bound: acc.bound + separator + String.length(string)
      }
    end
  end

  defp pieces_bound(pieces), do: Enum.sum_by(pieces, &String.length/1)

  defp within_budget(_acc, budget) when budget != :infinity and budget <= 0, do: :over_budget
  defp within_budget(%{bound: bound}, budget) when bound >= budget, do: :over_budget
  defp within_budget(acc, _budget), do: {:ok, acc}

  defp parenthesise(string) do
    if String.contains?(string, [" or ", " and "]), do: "(" <> string <> ")", else: string
  end

  defp parenthesise_and(string) do
    if String.contains?(string, " and not "), do: "(" <> string <> ")", else: string
  end

  defp line(ops, kind, {pos, negs}, memo) do
    positives = if pos == [], do: [top_literal(kind)], else: pos
    pos_descr = positives |> Enum.map(&%{kind => &1}) |> Enum.reduce(&ops.intersection/2)
    live = Enum.reject(negs, &Descr.disjoint?(pos_descr, %{kind => &1}))
    line = Enum.reduce(live, pos_descr, &ops.difference(&2, %{kind => &1}))

    if Descr.empty?(line) do
      {[], memo}
    else
      {positive_strings, memo} = Enum.map_reduce(positives, memo, &literal_string(kind, &1, &2))
      {negative_strings, memo} = Enum.map_reduce(live, memo, &literal_string(kind, &1, &2))
      positive = Enum.join(positive_strings, " and ")

      case negative_strings do
        [] -> {[positive], memo}
        [neg] -> {[positive <> " and not " <> neg], memo}
        negs -> {[positive <> " and not (" <> Enum.join(negs, " or ") <> ")"], memo}
      end
    end
  end

  defp literal_string(kind, literal, memo) do
    case memo do
      %{{^kind, ^literal} => string} ->
        {string, memo}

      %{} ->
        string = quoted(%{kind => literal})
        {string, Map.put(memo, {kind, literal}, string)}
    end
  end

  ## Components

  @doc """
  The per-kind components of the upper bound of `descr`
  (`c:SpecLint.Compiler.components/1`).
  """
  @spec components(module(), SpecLint.Compiler.descr()) :: [SpecLint.Compiler.component()]
  def components(ops, descr) do
    static = descr |> ops.expand() |> Descr.upper_bound() |> ops.expand()
    bitmap = Map.get(static, :bitmap, 0)

    bit_components(bitmap) ++
      atom_components(Map.get(static, :atom)) ++
      bdd_components(ops, :tuple, Map.get(static, :tuple)) ++
      bdd_components(ops, :map, Map.get(static, :map)) ++
      list_components(ops, Map.get(static, :list), band(bitmap, @bit_empty_list) != 0) ++
      fun_components(Map.get(static, :fun))
  end

  defp bit_components(bitmap) do
    for {kind, bit} <- @bit_kinds, band(bitmap, bit) != 0 do
      %{kind: kind, descr: %{bitmap: bit}, view: {:whole, kind}}
    end
  end

  defp atom_components(nil), do: []

  defp atom_components({:union, set} = atom) do
    case :sets.to_list(set) do
      [] -> []
      atoms -> [%{kind: :atom, descr: %{atom: atom}, view: {:atoms, Enum.sort(atoms)}}]
    end
  end

  defp atom_components({:negation, set} = atom) do
    view = if :sets.size(set) == 0, do: {:whole, :atom}, else: {:unknown, :atom, :negation}
    [%{kind: :atom, descr: %{atom: atom}, view: view}]
  end

  defp fun_components(nil), do: []

  defp fun_components(fun) do
    view =
      case fun do
        {:negation, bdds} when map_size(bdds) == 0 -> {:whole, :fun}
        _ -> {:unknown, :fun, :shape}
      end

    [%{kind: :fun, descr: %{fun: fun}, view: view}]
  end

  defp list_components(_ops, nil, false), do: []

  defp list_components(_ops, nil, true),
    do: [%{kind: :list, descr: %{bitmap: @bit_empty_list}, view: :empty_list}]

  defp list_components(ops, bdd, empty?) do
    case bdd_components(ops, :list, bdd) do
      [] ->
        list_components(ops, nil, empty?)

      lines when empty? ->
        Enum.map(lines, &with_empty_list(ops, &1))

      lines ->
        lines
    end
  end

  defp with_empty_list(ops, %{descr: descr, view: view} = component) do
    view =
      case view do
        {:list, element, tail, false} -> {:list, element, tail, true}
        other -> other
      end

    %{component | descr: ops.union(descr, %{bitmap: @bit_empty_list}), view: view}
  end

  defp bdd_components(_ops, _kind, nil), do: []

  defp bdd_components(ops, kind, bdd) do
    bdd
    |> Descr.bdd_to_dnf()
    |> Enum.reverse()
    |> Enum.flat_map(fn {pos, negs} -> line_components(ops, kind, pos, negs) end)
    |> Enum.uniq_by(& &1.descr)
  end

  defp line_components(ops, kind, pos, negs) do
    positives = if pos == [], do: [top_literal(kind)], else: pos
    pos_descr = positives |> Enum.map(&%{kind => &1}) |> Enum.reduce(&ops.intersection/2)
    line = Enum.reduce(negs, pos_descr, &ops.difference(&2, %{kind => &1}))

    cond do
      Descr.empty?(line) ->
        []

      match?([_, _ | _], positives) ->
        [%{kind: kind, descr: line, view: {:unknown, kind, :intersection}}]

      true ->
        [literal] = positives
        live = Enum.reject(negs, &Descr.disjoint?(pos_descr, %{kind => &1}))
        eliminate(ops, kind, literal, live, line)
    end
  end

  defp top_literal(:tuple), do: Descr.tuple().tuple
  defp top_literal(:map), do: Descr.open_map().map
  defp top_literal(:list), do: Descr.non_empty_list(Descr.term(), Descr.term()).list

  defp eliminate(ops, kind, literal, [], _line),
    do: [%{kind: kind, descr: %{kind => literal}, view: literal_view(ops, kind, literal)}]

  defp eliminate(ops, :tuple, {_, :closed, elements}, negs, line) do
    size = length(elements)

    if Enum.all?(negs, &same_size_negation?(&1, size)) do
      negs
      |> Enum.reduce([elements], fn {_, _, neg_elements}, acc ->
        padded = neg_elements ++ List.duplicate(Descr.term(), size - length(neg_elements))
        Enum.flat_map(acc, &tuple_split(ops, &1, padded))
      end)
      |> Enum.map(fn elements ->
        %{kind: :tuple, descr: Descr.tuple(elements), view: {:tuple, :closed, elements}}
      end)
    else
      [%{kind: :tuple, descr: line, view: {:unknown, :tuple, :negation}}]
    end
  end

  defp eliminate(_ops, kind, _literal, _negs, line),
    do: [%{kind: kind, descr: line, view: {:unknown, kind, :negation}}]

  defp same_size_negation?({_, :closed, neg_elements}, size), do: length(neg_elements) == size
  defp same_size_negation?({_, :open, neg_elements}, size), do: length(neg_elements) <= size
  defp same_size_negation?(_literal, _size), do: false

  # {t1..tn} and not {u1..un} is the union, over the first index i where a
  # value differs, of {t1 and u1, ..., ti - ui, t(i+1), ..., tn}.
  defp tuple_split(ops, elements, neg_elements) do
    if Enum.any?(Enum.zip(elements, neg_elements), fn {t, u} -> Descr.disjoint?(t, u) end) do
      [elements]
    else
      pairs = Enum.zip(elements, neg_elements)

      for index <- 0..(length(pairs) - 1),
          line = tuple_split_line(ops, pairs, index),
          not Enum.any?(line, &Descr.empty?/1),
          do: line
    end
  end

  defp tuple_split_line(ops, pairs, index) do
    pairs
    |> Enum.with_index()
    |> Enum.map(fn
      {{t, u}, i} when i < index -> ops.intersection(t, u)
      {{t, u}, ^index} -> ops.difference(t, u)
      {{t, _u}, _i} -> t
    end)
  end

  defp literal_view(_ops, :tuple, {_, :open, []}), do: {:whole, :tuple}
  defp literal_view(_ops, :tuple, {_, tag, elements}), do: {:tuple, tag, elements}
  defp literal_view(_ops, :map, {_, :open, []}), do: {:whole, :map}
  defp literal_view(ops, :map, literal), do: ops.map_view(literal)
  defp literal_view(_ops, :list, {_, element, tail}), do: {:list, element, tail, false}

  ## Canonical form
  #
  # Descr terms are maps of per-kind parts whose values are bitmaps, `:sets`
  # (maps in version 2), BDD tuples and literal tuples carrying
  # `:erlang.phash2/1` hashes. `phash2` is portable, so the only
  # VM-specific values are recursive type nodes (`{reference, state,
  # generator}`, on compiler lines that have them), which inference does
  # not produce today. They are unfolded to a fixed depth and cut off with a
  # marker. Maps are turned into sorted key/value lists so the result does
  # not depend on map iteration order.

  @canonical_node_depth 3

  @doc "The canonical form of `descr` (`c:SpecLint.Compiler.canonical/1`)."
  @spec canonical(module(), SpecLint.Compiler.descr()) :: term()
  def canonical(ops, descr), do: canonical_term(ops, descr, @canonical_node_depth)

  defp canonical_term(ops, map, depth) when is_map(map) do
    map
    |> Enum.map(fn {key, value} ->
      {canonical_term(ops, key, depth), canonical_term(ops, value, depth)}
    end)
    |> Enum.sort()
    |> then(&{:map, &1})
  end

  defp canonical_term(ops, tuple, depth) when is_tuple(tuple) do
    cond do
      not ops.recursive_node?(tuple) ->
        tuple |> Tuple.to_list() |> Enum.map(&canonical_term(ops, &1, depth)) |> List.to_tuple()

      depth == 0 ->
        :recursive_node

      true ->
        {:recursive_node, canonical_term(ops, ops.expand(tuple), depth - 1)}
    end
  end

  defp canonical_term(ops, [head | tail], depth),
    do: [canonical_term(ops, head, depth) | canonical_term(ops, tail, depth)]

  defp canonical_term(_ops, fun, _depth) when is_function(fun), do: :function
  defp canonical_term(_ops, ref, _depth) when is_reference(ref), do: :reference
  defp canonical_term(_ops, pid, _depth) when is_pid(pid) or is_port(pid), do: :process
  defp canonical_term(_ops, other, _depth), do: other
end
