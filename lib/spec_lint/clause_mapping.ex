defmodule SpecLint.ClauseMapping do
  @moduledoc """
  The source clauses a stored signature clause came from, where compiler
  invariants alone decide it (Milestone 4, `bench/clause_mapping/README.md`).

  The checker chunk stores, per function, the clauses left after the
  compiler grouped its per-source-clause inference; it does not record
  which source clauses each stored clause came from. This module maps them
  back only in the two cases where the order and count of clauses force the
  answer, with no type recomputed:

    * `:single` - the function has one source clause: every stored clause
      comes from it (including the several clauses of a default-argument
      wrapper, whose `{:super, ...}` body applies the arrows of the full
      definition);
    * `:identity` - the function has as many stored clauses as source
      clauses: stored clause `k` is source clause `k`.

  Every other shape is `:ambiguous`: the compiler merged clauses (equal
  argument types, or equal returns differing in one argument) or, on 1.21,
  dropped precise clauses whose return is empty, and which ones cannot be
  told from the stored signature without recomputing types. The Milestone 4
  experiment showed that recomputing head types is not exact (the checker
  leaks `subpatterns` between clauses and definitions, a redundant clause
  keeps the head left after subtracting earlier clauses, and a protocol
  implementation's head can leave the fresh upper bound), so no typed
  mapping is adopted.

  ## Invariants (checked in the source of every qualified build)

  For a `def`, `Module.Types.infer/7` stores
  `group_clauses_by_return(inferred)` under `sig`, unchanged by
  `elixir_erl:checker_chunk/4`. `local_handler/7` (types.ex 326-338 on
  `c24c235` and `648b2a9`, whose `types.ex` is identical; 330-342 on
  1.20.4) uses `default_local_handler/9` only for a single clause whose body
  is `{:super, ...}`, and `infer_local_handler/7` (396-441; 400-455)
  otherwise, which infers exactly one clause per source clause, in source
  order (a failure aborts compilation). Then:

    * I1 - each source clause ends in at most one stored clause, and each
      stored clause has at least one source clause: `group_clauses/1`
      (443-493, 1.21 only) keeps a subsequence (it drops precise clauses
      with an empty return when some return is not empty; 1.20.4 drops
      nothing), `add_inferred/5` (552-559; 511-518) merges a clause into
      the first earlier clause with term-equal arguments, and
      `group_clauses_by_return/1` (571-611; 530-570) merges it into the
      first earlier clause with the same return whose arguments differ in
      one position;
    * I2 - order: both merges keep a clause at the position of its first
      member and append a new one at the end, so stored clause `k`'s
      smallest source clause is smaller than stored clause `k + 1`'s.

  With one source clause, I1 gives every stored clause that clause. With
  `n` source and `n` stored clauses (`n > 1`, so `infer_local_handler/7`),
  I1 makes the map a bijection (a partial map onto `n` clauses from `n`
  clauses is total and one-to-one) and I2 makes it the identity. More stored
  than source clauses would break I1 and is reported as ambiguous
  (`:more_stored_than_source`), never trusted.

  Mapping a clause does not establish that it is reachable or that it
  returns; `clause_reachable` blocking stays function-wide
  (`SpecLint.Rules.ReturnConflict`).
  """

  @typedoc """
  A source clause: its 0-based position in the definition, its line, and
  the base name of its file when that is not the module's source file (a
  clause quoted with `location: :keep` in another file), else `nil`.
  """
  @type source_clause :: %{
          index: non_neg_integer(),
          line: pos_integer() | nil,
          file: String.t() | nil
        }

  @typedoc """
  `{:exact, class, per_stored}` gives, for each stored clause in order, the
  source clauses it came from; `{:ambiguous, reason}` gives none.
  """
  @type t ::
          {:exact, :single | :identity, [[source_clause()]]}
          | {:ambiguous, :merged_or_dropped | :more_stored_than_source | :no_source_clauses}

  @doc """
  Maps `stored_count` stored clauses to the source clauses of a `def`
  (`{meta, args, guards, body}` tuples from its debug info, in source
  order); `module_file` is the module's source file.
  """
  @spec map([tuple()], non_neg_integer(), String.t() | nil) :: t()
  def map(source_clauses, stored_count, module_file \\ nil) do
    sources =
      source_clauses |> Enum.with_index() |> Enum.map(&source(&1, module_file))

    n = length(sources)

    cond do
      n == 0 -> {:ambiguous, :no_source_clauses}
      n == 1 -> {:exact, :single, List.duplicate(sources, stored_count)}
      stored_count == n -> {:exact, :identity, Enum.map(sources, &[&1])}
      stored_count > n -> {:ambiguous, :more_stored_than_source}
      true -> {:ambiguous, :merged_or_dropped}
    end
  end

  @doc """
  The source clause of stored clause `index` when the mapping gives it
  exactly one, otherwise `:error`.
  """
  @spec source_clause(t() | nil, non_neg_integer()) :: {:ok, source_clause()} | :error
  def source_clause({:exact, _class, per_stored}, index) do
    case Enum.at(per_stored, index) do
      [clause] -> {:ok, clause}
      _other -> :error
    end
  end

  def source_clause(_mapping, _index), do: :error

  @doc "The class of a mapping: `:single`, `:identity` or `:ambiguous`."
  @spec class(t() | nil) :: :single | :identity | :ambiguous
  def class({:exact, class, _per_stored}), do: class
  def class(_mapping), do: :ambiguous

  @doc "A short text for a source clause: `#1, line 12` (with the file when it is another one)."
  @spec text(source_clause()) :: String.t()
  def text(%{index: index} = clause), do: "##{index}, " <> location(clause)

  defp location(%{line: nil}), do: "line unknown"
  defp location(%{line: line, file: nil}), do: "line #{line}"
  defp location(%{line: line, file: file}), do: "line #{line} of #{file}"

  defp source({{meta, _args, _guards, _body}, index}, module_file) do
    file =
      case Keyword.get(meta, :file) do
        {^module_file, _line} -> nil
        {file, _line} when is_binary(file) -> Path.basename(file)
        _other -> nil
      end

    %{index: index, line: line(Keyword.get(meta, :line)), file: file}
  end

  defp line(line) when is_integer(line) and line > 0, do: line
  defp line(_line), do: nil
end
