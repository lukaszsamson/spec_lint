defmodule SpecLint.OmissionFixtures.Num do
  @moduledoc false
  # Stands in for %Decimal{}: struct fields typed with literals and unions.
  defstruct sign: 1, coef: 0, exp: 0

  @type t :: %__MODULE__{
          sign: 1 | -1,
          coef: non_neg_integer() | :NaN | :inf,
          exp: integer()
        }
end

defmodule SpecLint.OmissionFixtures.Conn do
  @moduledoc false
  # Stands in for %Plug.Conn{}: a struct with a typed atom-keyed map field.
  defstruct private: %{}, status: nil

  @type t :: %__MODULE__{private: %{optional(atom()) => term()}, status: nil | 100..599}
end

defmodule SpecLint.OmissionFixtures.Changeset do
  @moduledoc false
  # Stands in for %Ecto.Changeset{}: `data` is a map or, in reality, nil.
  defstruct valid?: true, data: nil, changes: %{}, action: nil

  @type t :: %__MODULE__{
          valid?: boolean(),
          data: nil | map(),
          changes: %{optional(atom()) => term()},
          action: nil | atom()
        }
end

defmodule SpecLint.OmissionFixtures.Cases do
  @moduledoc false
  # Executable reproducers for the nine real omissions of EXPERIMENTS.md
  # "Real omissions found". Each function reproduces, in isolation, the
  # inference shape that hid one of them; bench/corpus/omissions/README.md
  # maps every fixture to its original MFA, corpus revision and file:line.
  # The current class of each is asserted by test/spec_lint/omissions_test.exs.

  alias SpecLint.OmissionFixtures.{Changeset, Conn, Num}

  ## Decimal.compare/2 and Decimal.cmp/2: a macro whose expansion is
  ## dynamic() hides the NaN struct returned when the trap is not set.

  defmacrop error(reason, result) do
    quote bind_quoted: binding() do
      case handle_error(reason, result) do
        {:ok, value} -> value
        {:error, reason} -> raise ArgumentError, inspect(reason)
      end
    end
  end

  defp handle_error(reason, result) do
    if reason in Process.get(:traps, []), do: {:error, reason}, else: {:ok, result}
  end

  @spec compare(Num.t(), Num.t()) :: :lt | :eq | :gt
  def compare(%Num{coef: :inf, sign: sign}, %Num{coef: :inf, sign: sign}), do: :eq
  def compare(%Num{coef: :inf, sign: 1}, _num2), do: :gt
  def compare(%Num{coef: :inf, sign: -1}, _num2), do: :lt
  def compare(%Num{coef: :NaN} = num1, _num2), do: error(:invalid_operation, num1)
  def compare(_num1, %Num{coef: :NaN} = num2), do: error(:invalid_operation, num2)
  def compare(%Num{coef: 0}, %Num{coef: 0}), do: :eq
  def compare(%Num{sign: 1}, %Num{sign: -1}), do: :gt
  def compare(%Num{sign: -1}, %Num{sign: 1}), do: :lt

  @spec cmp(Num.t(), Num.t()) :: :lt | :eq | :gt
  def cmp(num1, num2), do: compare(num1, num2)

  ## Plug.Conn.Query.decode/4: the argument type is too wide (keyword()
  ## admits atom keys), the body returns whatever Map.new/1 builds.

  @spec decode(String.t(), keyword()) :: %{optional(String.t()) => term()}
  def decode("", initial), do: Map.new(initial)

  def decode(query, initial) when is_binary(query) do
    query
    |> :binary.split("&", [:global])
    |> Enum.reduce(%{}, &decode_pair/2)
    |> decode_done(initial)
  end

  defp decode_pair(pair, acc) do
    case :binary.split(pair, "=") do
      [key, value] -> Map.put(acc, key, value)
      [key] -> Map.put(acc, key, nil)
    end
  end

  defp decode_done(acc, []), do: acc
  defp decode_done(acc, initial), do: Enum.into(acc, Map.new(initial))

  ## Plug.Conn.merge_private/2: struct in, struct out, the payload type of
  ## the map field is widened by Enum.into/2 (struct-minus-struct negation).

  @spec merge_private(Conn.t(), Enumerable.t()) :: Conn.t()
  def merge_private(%Conn{private: private} = conn, new) do
    %{conn | private: Enum.into(new, private)}
  end

  ## Ecto.Changeset.apply_action/2: the success payload is the changeset's
  ## `data`, which the spec declares as a map but a changeset may carry nil.

  @spec apply_action(Changeset.t(), atom()) :: {:ok, map()} | {:error, Changeset.t()}
  def apply_action(%Changeset{} = changeset, action) when is_atom(action) do
    if changeset.valid? do
      {:ok, apply_changes(changeset)}
    else
      {:error, %{changeset | action: action}}
    end
  end

  def apply_action(%Changeset{}, action) do
    raise ArgumentError, "expected action to be an atom, got: #{inspect(action)}"
  end

  defp apply_changes(%Changeset{changes: changes, data: data}) when changes == %{}, do: data

  defp apply_changes(%Changeset{changes: changes, data: data}) do
    Enum.reduce(changes, data, fn {key, value}, acc -> Map.put(acc, key, value) end)
  end

  ## Ecto.Query.Builder.Join.escape/3: stale spec, 5-tuples returned and
  ## 4-tuples declared. The recursive clauses and the Macro.expand catch-all
  ## make the union top-only; every parameter is unguarded.

  @spec join_escape(Macro.t(), keyword(), Macro.Env.t()) ::
          {atom(), Macro.t() | nil, Macro.t() | nil, list()}
  def join_escape({:in, _, [{var, _, context}, expr]}, vars, env)
      when is_atom(var) and is_atom(context) do
    {_, expr, assoc, prelude, params} = join_escape(expr, vars, env)
    {var, expr, assoc, prelude, params}
  end

  def join_escape({:subquery, _, [expr]}, _vars, _env) do
    {:_, quote(do: subquery(unquote(expr))), nil, nil, []}
  end

  def join_escape({:assoc, _, [{var, _, context}, field]}, _vars, _env)
      when is_atom(var) and is_atom(context) do
    {:_, nil, {var, field}, nil, []}
  end

  def join_escape(string, _vars, _env) when is_binary(string),
    do: {:_, {string, nil}, nil, nil, []}

  def join_escape(schema, _vars, _env) when is_atom(schema), do: {:_, {nil, schema}, nil, nil, []}

  def join_escape(join, vars, env) do
    case Macro.expand(join, env) do
      ^join -> raise ArgumentError, "malformed join `#{Macro.to_string(join)}`"
      join -> join_escape(join, vars, env)
    end
  end

  ## Ecto.Query.Builder.quoted_type/2: stale spec, the clauses return :atom,
  ## {:tuple, _} and {{:{}, [], _}, _} pairs, none of them declared. Recursion
  ## through Enum.map and a catch-all make the union top-only.

  @type primitive ::
          :string | :integer | :float | :boolean | :binary | {:array, primitive() | :any}
  @type quoted_type :: primitive() | {non_neg_integer(), atom() | Macro.t()}

  @spec quoted_type(Macro.t(), keyword()) :: quoted_type()
  def quoted_type({{:., _, [{var, _, context}, field]}, _, []}, vars)
      when is_atom(var) and is_atom(context) and is_atom(field),
      do: {Keyword.fetch!(vars, var), field}

  def quoted_type({{:., _, [{kind, _, [value]}, field]}, _, []}, _vars)
      when kind in [:as, :parent_as],
      do: {{:{}, [], [kind, [], [value]]}, field}

  def quoted_type({:<<>>, _, _}, _vars), do: :binary
  def quoted_type(literal, _vars) when is_float(literal), do: :float
  def quoted_type(literal, _vars) when is_binary(literal), do: :string
  def quoted_type(literal, _vars) when is_boolean(literal), do: :boolean
  def quoted_type(literal, _vars) when is_atom(literal) and not is_nil(literal), do: :atom
  def quoted_type(literal, _vars) when is_integer(literal), do: :integer

  def quoted_type(list, vars) when is_list(list) do
    case list |> Enum.map(&quoted_type(&1, vars)) |> Enum.uniq() do
      [type] -> {:array, type}
      _ -> {:array, :any}
    end
  end

  def quoted_type({:{}, _, elems}, vars), do: {:tuple, Enum.map(elems, &quoted_type(&1, vars))}
  def quoted_type(_, _vars), do: :any

  ## Ecto.Repo.Assoc.query/4: the spec says a list of schemas, Enum.map/2
  ## applies a fun whose spec is (list -> list), so the elements are rows.

  @spec assoc_query([list()], list(), tuple(), (list() -> list())) :: [struct()]
  def assoc_query([], _assocs, _sources, _fun), do: []
  def assoc_query(rows, [], _sources, fun), do: Enum.map(rows, fun)

  def assoc_query(rows, assocs, sources, fun) do
    accs = create_accs(assocs, sources, [])

    {rows, _} =
      Enum.reduce(rows, {[], accs}, fn row, {seen, acc} -> {[fun.(row) | seen], acc} end)

    for [item | sub_structs] <- Enum.reverse(rows) do
      [load_assocs(item, assocs) | sub_structs]
    end
  end

  defp create_accs([], _sources, acc), do: Enum.reverse(acc)

  defp create_accs([assoc | rest], sources, acc),
    do: create_accs(rest, sources, [{assoc, sources} | acc])

  defp load_assocs(item, assocs), do: Enum.reduce(assocs, item, &Map.put(&2, &1, nil))

  ## Ecto.Repo.Preloader.query/7: same as above but with an untyped fun and
  ## a private recursive helper, so the elements are whatever fun returns.

  @spec preloader_query(
          [list()],
          term(),
          list(),
          Access.t(),
          list(),
          fun(),
          {map(), keyword()}
        ) :: [list()]
  def preloader_query([], _repo, _preloads, _take, _assocs, _fun, _tuplet), do: []
  def preloader_query(rows, _repo, [], _take, _assocs, fun, _tuplet), do: Enum.map(rows, fun)

  def preloader_query(rows, repo, preloads, take, assocs, fun, tuplet) do
    rows
    |> extract()
    |> preload_each(repo, preloads, take, assocs, tuplet)
    |> unextract(rows, fun)
  end

  defp extract([[nil | _] | t2]), do: extract(t2)
  defp extract([[h | _] | t2]), do: [h | extract(t2)]
  defp extract([]), do: []

  defp preload_each(structs, _repo, _preloads, _take, _assocs, _tuplet), do: structs

  defp unextract(structs, [[nil | _] = h2 | t2], fun),
    do: [fun.(h2) | unextract(structs, t2, fun)]

  defp unextract([h1 | structs], [[_ | t1] | t2], fun),
    do: [fun.([h1 | t1]) | unextract(structs, t2, fun)]

  defp unextract([], [], _fun), do: []
end
