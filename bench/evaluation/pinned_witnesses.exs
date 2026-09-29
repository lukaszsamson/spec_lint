# Runtime witnesses on the PINNED library builds for the omissions that had
# only stand-in witnesses (test/spec_lint/omissions_test.exs) or a witness
# recorded in prose (Absinthe.Blueprint.Input.parse/1). Part of the frozen
# evaluation inventory (bench/evaluation/INVENTORY.md).
#
#   elixir bench/evaluation/pinned_witnesses.exs OSS_ROOT EXPANSION_ROOT
#
# OSS_ROOT holds the decimal, plug and ecto checkouts, EXPANSION_ROOT the
# absinthe checkout, each compiled with MIX_ENV=test at the revision pinned
# in bench/corpus/run.sh and bench/corpus/expansion.json. The script loads
# their ebin directories without starting any application, calls only pure
# functions, and checks every input against the declared argument types and
# every result against the declared return type with predicates written by
# hand from the spec text. It does not call SpecLint. It raises when a pinned
# observation or verdict changes, and prints the observations as JSON.

[oss, expansion] =
  case System.argv() do
    [oss, expansion] -> [oss, expansion]
    _ -> raise "usage: elixir pinned_witnesses.exs OSS_ROOT EXPANSION_ROOT"
  end

pins = %{
  "decimal" => {oss, "92a28e6b9a103f2b52a22b3f772f7a2a34b7b1d5"},
  "plug" => {oss, "73404f851852a00ffb2014be95d4598900fa77b8"},
  "ecto" => {oss, "94d69279c517347ff0962b138f4ccd0556486ae2"},
  "absinthe" => {expansion, "1372ceb5f8226175050a38821601cd57738c177b"}
}

# Dependencies are taken from the project that needs them; decimal comes from
# the decimal corpus only, so the pinned Decimal is the one loaded.
ebins = [
  {"decimal", "decimal"},
  {"plug", "plug"},
  {"plug", "mime"},
  {"plug", "plug_crypto"},
  {"plug", "telemetry"},
  {"ecto", "ecto"},
  {"absinthe", "absinthe"}
]

for {project, {root, revision}} <- pins do
  {head, status} = System.cmd("git", ["-C", Path.join(root, project), "rev-parse", "HEAD"])

  unless status == 0 and String.trim(head) == revision do
    raise "#{project} must be at the pinned revision #{revision}"
  end
end

for {project, app} <- ebins do
  {root, _} = Map.fetch!(pins, project)
  ebin = Path.join([root, project, "_build", "test", "lib", app, "ebin"])
  unless File.dir?(ebin), do: raise("compiled ebin missing: #{ebin}")
  Code.prepend_path(ebin)
end

defmodule Witness.Types do
  @moduledoc false
  # Hand-written predicates, one per declared type used below. Each cites
  # the declaration it reads.

  # decimal lib/decimal.ex:116-129,213-221: t :: %Decimal{sign: 1 | -1,
  # coef: non_neg_integer | :NaN | :inf, exp: integer}; decimal :: t | integer
  # | String.t(); compare_result :: :lt | :gt | :eq (139-140).
  @spec decimal?(term()) :: boolean()
  def decimal?(%Decimal{sign: s, coef: c, exp: e}),
    do: Enum.all?([s in [1, -1], coefficient?(c), is_integer(e)])

  def decimal?(v), do: is_integer(v) or is_binary(v)

  defp coefficient?(c) when is_integer(c), do: c >= 0
  defp coefficient?(c), do: c in [:NaN, :inf]

  @spec compare_result?(term()) :: boolean()
  def compare_result?(v), do: v in [:lt, :gt, :eq]

  # plug lib/plug/conn/query.ex:108: decode(String.t(), keyword(), module(),
  # boolean()) :: %{optional(String.t()) => term()}.
  @spec keyword?(term()) :: boolean()
  def keyword?(v), do: is_list(v) and Enum.all?(v, &match?({k, _} when is_atom(k), &1))

  @spec string_keyed_map?(term()) :: boolean()
  def string_keyed_map?(v), do: is_map(v) and Enum.all?(Map.keys(v), &is_binary/1)

  # plug lib/plug/conn.ex:168-218: the fields of Plug.Conn.t() whose types
  # are checkable without a nested struct: adapter {module, term}, assigns
  # and private %{optional(atom) => any}, halted boolean, host and method
  # binary, owner pid | nil, port 0..65535, remote_ip :inet.ip_address(),
  # req_headers and resp_headers [{binary, binary}], request_path binary,
  # scheme :http | :https, script_name and path_info [binary], secret_key_base
  # binary | nil, status non_neg_integer | nil, state one of eight atoms.
  @states [:unset, :set, :set_chunked, :set_file, :file, :chunked, :sent, :upgraded]

  @spec conn_t?(term()) :: boolean()
  def conn_t?(%Plug.Conn{} = c) do
    Enum.all?([
      match?({m, _} when is_atom(m), c.adapter),
      atom_keyed?(c.assigns),
      atom_keyed?(c.private),
      is_boolean(c.halted),
      is_binary(c.host),
      is_binary(c.method),
      is_pid(c.owner) or is_nil(c.owner),
      c.port in 0..65_535,
      ip_address?(c.remote_ip),
      headers?(c.req_headers),
      headers?(c.resp_headers),
      is_binary(c.request_path),
      c.scheme in [:http, :https],
      binaries?(c.script_name),
      binaries?(c.path_info),
      is_binary(c.secret_key_base) or is_nil(c.secret_key_base),
      non_neg_or_nil?(c.status),
      c.state in @states
    ])
  end

  def conn_t?(_), do: false

  defp atom_keyed?(m), do: is_map(m) and Enum.all?(Map.keys(m), &is_atom/1)
  defp binaries?(l), do: is_list(l) and Enum.all?(l, &is_binary/1)
  defp non_neg_or_nil?(n), do: is_nil(n) or (is_integer(n) and n >= 0)

  defp headers?(h),
    do: is_list(h) and Enum.all?(h, &match?({k, v} when is_binary(k) and is_binary(v), &1))

  defp ip_address?({_, _, _, _} = t), do: t |> Tuple.to_list() |> Enum.all?(&(&1 in 0..255))

  defp ip_address?({_, _, _, _, _, _, _, _} = t),
    do: t |> Tuple.to_list() |> Enum.all?(&(&1 in 0..65_535))

  defp ip_address?(_), do: false

  # ecto lib/ecto/changeset.ex:391-410,419: t :: t(Ecto.Schema.t() | map |
  # nil) with valid? boolean, repo atom | nil, repo_opts keyword, params
  # %{optional(String.t()) => term} | nil, changes %{optional(atom) => term},
  # required [atom], prepare [fun], errors, constraints, validations lists,
  # filters %{optional(atom) => term}, action atom | nil, types map;
  # data :: map(). Ecto.Schema.t() is a struct (schema.ex:508), so a map.
  @spec changeset_t?(term()) :: boolean()
  def changeset_t?(%Ecto.Changeset{} = c) do
    Enum.all?([
      is_boolean(c.valid?),
      is_atom(c.repo),
      keyword?(c.repo_opts),
      is_map(c.data) or is_nil(c.data),
      is_nil(c.params) or string_keyed_map?(c.params),
      atom_keyed?(c.changes),
      Enum.all?(c.required, &is_atom/1),
      Enum.all?(c.prepare, &is_function(&1, 1)),
      is_list(c.errors),
      is_list(c.constraints),
      is_list(c.validations),
      atom_keyed?(c.filters),
      is_atom(c.action),
      is_map(c.types)
    ])
  end

  def changeset_t?(_), do: false

  # apply_action/2 (changeset.ex:2337): {:ok, Ecto.Schema.t() | data} |
  # {:error, t}; apply_changes/1 (2298): Ecto.Schema.t() | data.
  @spec apply_action_return?(term()) :: boolean()
  def apply_action_return?({:ok, data}), do: is_map(data)
  def apply_action_return?({:error, c}), do: changeset_t?(c)
  def apply_action_return?(_), do: false

  # ecto lib/ecto/query/builder/join.ex:45-46: escape(Macro.t(), Keyword.t(),
  # Macro.Env.t()) :: {atom, Macro.t() | nil, Macro.t() | nil, list}.
  @spec join_escape_return?(term()) :: boolean()
  def join_escape_return?({a, _, _, l}) when is_atom(a) and is_list(l), do: true
  def join_escape_return?(_), do: false

  # ecto lib/ecto/query/builder.ex:55 and lib/ecto/type.ex:202-230:
  # quoted_type :: Ecto.Type.primitive() | {non_neg_integer, atom | Macro.t()}.
  @base ~w(integer float boolean string bitstring map binary decimal id binary_id
           utc_datetime naive_datetime date time any utc_datetime_usec
           naive_datetime_usec time_usec duration)a

  @spec primitive?(term()) :: boolean()
  def primitive?(t) when t in @base, do: true
  def primitive?({tag, t}) when tag in [:array, :map, :try, :in], do: ecto_type?(t)
  def primitive?({:supertype, :datetime}), do: true
  def primitive?(_), do: false

  # Ecto.Type.t :: primitive | custom (module | {:parameterized, {module, term}})
  defp ecto_type?({:parameterized, {m, _}}) when is_atom(m), do: true
  defp ecto_type?(t), do: is_atom(t) or primitive?(t)

  @spec quoted_type_return?(term()) :: boolean()
  def quoted_type_return?({n, _}) when is_integer(n) and n >= 0, do: true
  def quoted_type_return?(t), do: primitive?(t)

  # ecto lib/ecto/repo/assoc.ex:10: query([list], list, tuple, (list -> list))
  # :: [Ecto.Schema.t]; preloader.ex:15-23: query([list], Ecto.Repo.t(), list,
  # Access.t(), list, fun, {map, Keyword.t()}) :: [list].
  @spec list_of_structs?(term()) :: boolean()
  def list_of_structs?(v), do: is_list(v) and Enum.all?(v, &is_struct/1)

  @spec list_of_lists?(term()) :: boolean()
  def list_of_lists?(v), do: is_list(v) and Enum.all?(v, &is_list/1)

  # absinthe lib/absinthe/blueprint/input.ex:21,36: parse(any) :: nil | t,
  # with t a union of Input.* structs whose source_location field is
  # Blueprint.SourceLocation.t() (e.g. input/integer.ex:15-21), a struct with
  # pos_integer line and column (source_location.ex:10-13). Only the field
  # at issue is checked; a struct of another module is outside t().
  @input ~w(Integer Float Null String Boolean List Object Enum Variable Value Argument)
         |> Enum.map(&Module.concat(Absinthe.Blueprint.Input, &1))

  @spec parse_return?(term()) :: boolean()
  def parse_return?(nil), do: true
  def parse_return?(%struct{} = v) when struct in @input, do: location?(v.source_location)
  def parse_return?(_), do: false

  defp location?(%Absinthe.Blueprint.SourceLocation{line: l, column: c}),
    do: is_integer(l) and l > 0 and is_integer(c) and c > 0

  defp location?(_), do: false
end

alias Witness.Types, as: T

# A Plug.Conn is shown by the field at issue only.
observed = fn
  %{__struct__: Plug.Conn, private: private} -> "%Plug.Conn{private: #{inspect(private)}, ...}"
  result -> inspect(result, limit: 8, printable_limit: 60)
end

nan_off = fn f ->
  Decimal.Context.with(%{Decimal.Context.get() | traps: []}, f)
end

# cmp/2 is @deprecated; a variable module avoids the compile-time warning.
deprecated = Decimal
nan = Decimal.new("NaN")
one = Decimal.new(1)
conn = struct!(Plug.Conn, remote_ip: {127, 0, 0, 1})
changeset_nil = struct!(Ecto.Changeset, valid?: true)
changeset_map = struct!(Ecto.Changeset, valid?: true, data: %{})
changeset_default = struct!(Ecto.Changeset)
changeset_default_map = struct!(Ecto.Changeset, data: %{})
pass = fn row -> row end
tuplet = {%{}, []}
loc = struct!(Absinthe.Blueprint.SourceLocation, line: 1, column: 1)

# {id, mfa, witness?, input text, input in domain?, thunk, return predicate}
cases =
  [
    {"decimal_compare_nan", "Decimal.compare/2", true,
     "Decimal.compare(Decimal.new(\"NaN\"), Decimal.new(1)) with traps: []",
     T.decimal?(nan) and T.decimal?(one), fn -> nan_off.(fn -> Decimal.compare(nan, one) end) end,
     &T.compare_result?/1},
    {"decimal_compare_control", "Decimal.compare/2", false, "Decimal.compare(1, 2)", true,
     fn -> Decimal.compare(1, 2) end, &T.compare_result?/1},
    {"decimal_cmp_nan", "Decimal.cmp/2", true,
     "Decimal.cmp(Decimal.new(\"NaN\"), Decimal.new(1)) with traps: []",
     T.decimal?(nan) and T.decimal?(one), fn -> nan_off.(fn -> deprecated.cmp(nan, one) end) end,
     &(&1 in [:lt, :eq, :gt])},
    {"decimal_cmp_control", "Decimal.cmp/2", false, "Decimal.cmp(1, 2)", true,
     fn -> deprecated.cmp(1, 2) end, &(&1 in [:lt, :eq, :gt])},
    {"plug_query_decode_atom_key", "Plug.Conn.Query.decode/4", true,
     "Plug.Conn.Query.decode(\"\", [unexpected: 1], Plug.Conn.InvalidQueryError, true)",
     T.keyword?(unexpected: 1),
     fn -> Plug.Conn.Query.decode("", [unexpected: 1], Plug.Conn.InvalidQueryError, true) end,
     &T.string_keyed_map?/1},
    {"plug_query_decode_control", "Plug.Conn.Query.decode/4", false,
     "Plug.Conn.Query.decode(\"a=1\", [], Plug.Conn.InvalidQueryError, true)", true,
     fn -> Plug.Conn.Query.decode("a=1", [], Plug.Conn.InvalidQueryError, true) end,
     &T.string_keyed_map?/1},
    {"plug_merge_private_binary_key", "Plug.Conn.merge_private/2", true,
     "Plug.Conn.merge_private(%Plug.Conn{remote_ip: {127, 0, 0, 1}}, [{\"unexpected\", 1}])",
     T.conn_t?(conn), fn -> Plug.Conn.merge_private(conn, [{"unexpected", 1}]) end, &T.conn_t?/1},
    {"plug_merge_private_control", "Plug.Conn.merge_private/2", false,
     "Plug.Conn.merge_private(%Plug.Conn{remote_ip: {127, 0, 0, 1}}, [expected: 1])",
     T.conn_t?(conn), fn -> Plug.Conn.merge_private(conn, expected: 1) end, &T.conn_t?/1},
    {"ecto_apply_action_nil_data", "Ecto.Changeset.apply_action/2", true,
     "Ecto.Changeset.apply_action(%Ecto.Changeset{valid?: true}, :insert)",
     T.changeset_t?(changeset_nil), fn -> Ecto.Changeset.apply_action(changeset_nil, :insert) end,
     &T.apply_action_return?/1},
    {"ecto_apply_action_control", "Ecto.Changeset.apply_action/2", false,
     "Ecto.Changeset.apply_action(%Ecto.Changeset{valid?: true, data: %{}}, :insert)",
     T.changeset_t?(changeset_map), fn -> Ecto.Changeset.apply_action(changeset_map, :insert) end,
     &T.apply_action_return?/1},
    {"ecto_apply_changes_nil_data", "Ecto.Changeset.apply_changes/1", true,
     "Ecto.Changeset.apply_changes(%Ecto.Changeset{})", T.changeset_t?(changeset_default),
     fn -> Ecto.Changeset.apply_changes(changeset_default) end, &is_map/1},
    {"ecto_apply_changes_control", "Ecto.Changeset.apply_changes/1", false,
     "Ecto.Changeset.apply_changes(%Ecto.Changeset{data: %{}})",
     T.changeset_t?(changeset_default_map),
     fn -> Ecto.Changeset.apply_changes(changeset_default_map) end, &is_map/1},
    {"ecto_join_escape_five_tuple", "Ecto.Query.Builder.Join.escape/3", true,
     "Ecto.Query.Builder.Join.escape(quote(do: x in fragment(\"foo\")), [], __ENV__)", true,
     fn -> Ecto.Query.Builder.Join.escape(quote(do: x in fragment("foo")), [], __ENV__) end,
     &T.join_escape_return?/1},
    {"ecto_quoted_type_atom", "Ecto.Query.Builder.quoted_type/2", true,
     "Ecto.Query.Builder.quoted_type(:example, [])", true,
     fn -> Ecto.Query.Builder.quoted_type(:example, []) end, &T.quoted_type_return?/1},
    {"ecto_quoted_type_control", "Ecto.Query.Builder.quoted_type/2", false,
     "Ecto.Query.Builder.quoted_type(1, [])", true,
     fn -> Ecto.Query.Builder.quoted_type(1, []) end, &T.quoted_type_return?/1},
    {"ecto_assoc_query_rows", "Ecto.Repo.Assoc.query/4", true,
     "Ecto.Repo.Assoc.query([[1]], [], {}, fn row -> row end)", true,
     fn -> Ecto.Repo.Assoc.query([[1]], [], {}, pass) end, &T.list_of_structs?/1},
    {"ecto_assoc_query_control", "Ecto.Repo.Assoc.query/4", false,
     "Ecto.Repo.Assoc.query([], [], {}, fn row -> row end)", true,
     fn -> Ecto.Repo.Assoc.query([], [], {}, pass) end, &T.list_of_structs?/1},
    {"ecto_preloader_query_non_list", "Ecto.Repo.Preloader.query/7", true,
     "Ecto.Repo.Preloader.query([[1]], MyRepo, [], nil, [], fn _ -> :unexpected end, {%{}, []})",
     true,
     fn ->
       Ecto.Repo.Preloader.query([[1]], MyRepo, [], nil, [], fn _ -> :unexpected end, tuplet)
     end, &T.list_of_lists?/1},
    {"ecto_preloader_query_control", "Ecto.Repo.Preloader.query/7", false,
     "Ecto.Repo.Preloader.query([[1]], MyRepo, [], nil, [], fn row -> row end, {%{}, []})", true,
     fn -> Ecto.Repo.Preloader.query([[1]], MyRepo, [], nil, [], pass, tuplet) end,
     &T.list_of_lists?/1}
  ] ++
    for {input, text} <- [
          {1, "1"},
          {1.0, "1.0"},
          {nil, "nil"},
          {"s", "\"s\""},
          {true, "true"},
          {[], "[]"},
          {%{}, "%{}"}
        ] do
      {"absinthe_parse_#{text}", "Absinthe.Blueprint.Input.parse/1", true,
       "Absinthe.Blueprint.Input.parse(#{text})", true,
       fn -> Absinthe.Blueprint.Input.parse(input) end, &T.parse_return?/1}
    end ++
    [
      {"absinthe_parse_control", "Absinthe.Blueprint.Input.parse/1", false,
       "Absinthe.Blueprint.Input.parse(%Input.Integer{value: 1, source_location: %SourceLocation{line: 1, column: 1}})",
       true,
       fn ->
         Absinthe.Blueprint.Input.parse(
           struct!(Absinthe.Blueprint.Input.Integer, value: 1, source_location: loc)
         )
       end, &T.parse_return?/1}
    ]

observations =
  for {id, mfa, witness?, input, in_domain?, thunk, return?} <- cases do
    result = thunk.()
    inside = return?.(result)

    unless in_domain?, do: raise("#{id}: input outside the declared domain")

    if witness? == inside do
      raise "#{id}: expected the result #{if witness?, do: "outside", else: "inside"} " <>
              "the declared return, got #{inspect(result)}"
    end

    %{
      case: id,
      mfa: mfa,
      role: if(witness?, do: "witness", else: "control"),
      input: input,
      input_in_declared_domain: in_domain?,
      observed: observed.(result),
      inside_declared_return: inside
    }
  end

IO.puts(
  JSON.encode!(%{
    schema: "spec_lint/pinned_witnesses",
    revisions: Map.new(pins, fn {project, {_, revision}} -> {project, revision} end),
    elixir: System.version(),
    observations: observations
  })
)
