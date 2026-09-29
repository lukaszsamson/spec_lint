defmodule SpecLint.Compiler.V120 do
  @moduledoc """
  Compiler adapter for Elixir 1.20 with checker chunk
  `:elixir_checker_v8`.

  Qualified for the Elixir 1.20.4 release only (revision `759443e`, the
  `v1.20.4` tag), with the pinned compiler modules of the precompiled
  release (`qualified_builds/0`). The audit of every internal SpecLint reads,
  against the 1.21 adapter (`SpecLint.Compiler.V121`), is
  `bench/corpus/toolchain/audit-1.20.4.md`. Preflight is the shared one
  (`SpecLint.Compiler.Qualification`): revision, compiler identity, then
  one capability probe per internal, with this adapter's `Descr` export
  list, encoding and semantic checks.

  What differs from 1.21, and is kept here:

    * set operations are `union/2`, `intersection/2` and `difference/2`
      (1.21 has `opt_union/2` and friends);
    * a map field is optional when its value carries the `not_set()`
      marker (`optional: 1` in the value, added by `if_set/1`), not
      through an `{value, optional?}` pair; key domain values carry the
      marker too, and the domain of bitstrings that are not binaries is
      named `:bitstring` (1.21: `:bitstring_no_binary`). `closed_map/2`
      and `map_view/1` translate both ways, and every value this adapter
      hands out has the marker removed, so no `:optional` part reaches the
      rest of SpecLint;
    * there are no recursive type nodes and no public `unfold/1`: `term()`
      is expanded here (`expand/1`), `recursive_types?/0` is `false`, and
      recursive typespecs are cut off by `SpecLint.Translate` with
      `:recursive_cutoff`, as on 1.21 (SpecLint builds no recursive
      descr on any line);
    * `apply_infer/2` reduces the returns with `union/2` (the 1.20.4
      source is otherwise identical to 1.21's, `@max_clauses 16`).

  Functions that only this line's `Descr` exports are called through
  `:erlang.apply/3`, so that compiling SpecLint with a 1.21 compiler, and
  Dialyzer there, see no call to a function its `Descr` lacks.
  """

  @behaviour SpecLint.Compiler
  @behaviour SpecLint.Compiler.Qualification
  @behaviour SpecLint.Compiler.DescrWalk

  alias Module.Types.Descr
  alias SpecLint.Compiler.{BuildIdentity, DescrWalk, Qualification}

  # Mirrors Module.Types.Apply @max_clauses.
  @max_clauses 16
  @checker_version :elixir_checker_v8
  @version_requirement "~> 1.20.4"
  # Elixir revisions (short SHA, `System.build_info()[:revision]`) against
  # which the apply_infer/2 copy, the Descr encodings and every other
  # internal were qualified (bench/corpus/toolchain/audit-1.20.4.md).
  @qualified_revisions ["759443e"]

  # Per qualified revision, the code digests of the pinned compiler modules
  # (SpecLint.Compiler.BuildIdentity), printed by
  # bench/corpus/toolchain/pinned_digests.exs on the qualified build: the
  # precompiled 1.20.4 release for OTP 29 (the same digests when it runs
  # on OTP 28.5.0.1 and 29.0.1).
  @qualified_builds %{
    "759443e" => %{
      "Elixir.Code.Typespec" =>
        "9bd9368efc8579e90a7038af36c0349d803b19830442da4e0ca4ad64ddf3dcb2",
      "Elixir.Mix.Compilers.Elixir" =>
        "1765eec37c57ccc349dc1fd7c87c9550f56a9b380d5a3033c80f628ed25b175a",
      "Elixir.Module.ParallelChecker" =>
        "a3221969dfe2a340bb7b5fcae6304e6d23d4b726fe5be22fe620c53d533ffe89",
      "Elixir.Module.Types" => "854d0bfff3bef547e98aa20d65f28db8885091f71f1fbb4bb44544abad8c571c",
      "Elixir.Module.Types.Apply" =>
        "1c03c0c60568c58f8bf4a471dd69b069257d268d8de38de643d8d217f760be94",
      "Elixir.Module.Types.Descr" =>
        "b84e1e6855407dd92d5f676fe1b2fa4c1eab71e823236b3587580c7f8bc7aeb7",
      "Elixir.Module.Types.Expr" =>
        "a26b2a512ff414e7807af0b6d5e73833d1520f1fdb41c237ae74493c3573c3c0",
      "Elixir.Module.Types.Helpers" =>
        "2ae8fed9a85f3f9d22c96d54e81489823979a23ebe21873f8ebff881da790fc5",
      "Elixir.Module.Types.Of" =>
        "9a59511506910d8f7e96905a3168380bcb4fcf7cd0ce5ea4f3f57f38240c6311",
      "Elixir.Module.Types.Pattern" =>
        "36bcec684cc2ab689ddfc7bc1587e99b2acadad44005763b0909c98f270bccb7",
      "Elixir.Module.Types.Traverse" =>
        "64d70edbdf9bb097f88c604ec9b0c807883a233e205c9058a549838918e75681",
      "elixir_def" => "e60c235daef4ea5fe64dbea576f50e0523c9e6c7a43034a7908f291d4363a83b",
      "elixir_erl" => "1692ffbaa14b79508793139f9562446b18938db1707eedd2e64543450c3f7a27",
      "elixir_overridable" => "5270b007db55941e83ad6487d4e0c30cdfef7668249a97fd06d521800f53235d"
    }
  }

  # Map key domain kinds as SpecLint names them (SpecLint.Compiler.key_kind)
  # and as this line's Descr names them, where they differ.
  @key_kinds [
    :atom,
    :binary,
    :bitstring_no_binary,
    :float,
    :fun,
    :integer,
    :list,
    :map,
    :pid,
    :port,
    :reference,
    :tuple
  ]

  # Descr functions this adapter calls. Probed by preflight/0.
  @required_descr [
    none: 0,
    term: 0,
    dynamic: 0,
    dynamic: 1,
    atom: 0,
    atom: 1,
    integer: 0,
    float: 0,
    binary: 0,
    bitstring: 0,
    bitstring_no_binary: 0,
    pid: 0,
    port: 0,
    reference: 0,
    boolean: 0,
    empty_list: 0,
    list: 1,
    non_empty_list: 2,
    tuple: 0,
    tuple: 1,
    open_tuple: 1,
    empty_map: 0,
    open_map: 0,
    closed_map: 1,
    fun: 0,
    fun: 1,
    fun: 2,
    union: 2,
    intersection: 2,
    difference: 2,
    if_set: 1,
    subtype?: 2,
    disjoint?: 2,
    empty?: 1,
    equal?: 2,
    gradual?: 1,
    upper_bound: 1,
    lower_bound: 1,
    to_quoted_string: 2,
    atom_fetch: 1,
    to_domain_keys: 1,
    bdd_to_dnf: 1
  ]

  @typedoc "See `SpecLint.Compiler.Qualification.internals/0`."
  @type internals :: Qualification.internals()

  @typedoc "See `SpecLint.Compiler.Qualification.probe/0`."
  @type probe :: Qualification.probe()

  ## Qualification

  @impl SpecLint.Compiler
  @spec preflight() :: {:ok, SpecLint.Compiler.capabilities()} | {:error, term()}
  def preflight, do: preflight(internals())

  @doc """
  `preflight/0` against `internals` (`SpecLint.Compiler.Qualification.preflight/2`).
  """
  @spec preflight(internals()) :: {:ok, SpecLint.Compiler.capabilities()} | {:error, term()}
  def preflight(internals), do: Qualification.preflight(__MODULE__, internals)

  @doc "The running compiler's internals, as `preflight/1` probes them."
  @spec internals() :: internals()
  def internals, do: Qualification.internals()

  @doc "The capability probes `preflight/1` runs, in order."
  @spec capability_probes() :: [probe(), ...]
  def capability_probes, do: Qualification.probes()

  @impl Qualification
  @spec qualified_revisions() :: [String.t(), ...]
  def qualified_revisions, do: @qualified_revisions

  @impl Qualification
  @spec qualified_builds() :: %{String.t() => BuildIdentity.digests()}
  def qualified_builds, do: @qualified_builds

  @impl Qualification
  @spec version_requirement() :: String.t()
  def version_requirement, do: @version_requirement

  @impl Qualification
  @spec required_descr() :: [{atom(), 0 | 1 | 2}, ...]
  def required_descr, do: @required_descr

  @impl Qualification
  @spec recursive_types?() :: false
  def recursive_types?, do: false

  @impl Qualification
  @spec nominal_types?() :: false
  def nominal_types?, do: false

  @doc """
  Checks an Elixir version and build revision against this adapter's
  qualification. Used by `preflight/0` with the running build's values.
  """
  @spec check_build(String.t(), String.t() | nil) ::
          :ok
          | {:error, {:unsupported_elixir, String.t(), String.t()}}
          | {:error, {:unqualified_revision, String.t() | nil, [String.t()]}}
  def check_build(version, revision), do: Qualification.check_build(__MODULE__, version, revision)

  @doc "Runs one capability probe (`SpecLint.Compiler.Qualification.probe/3`)."
  @spec probe(probe(), internals()) :: :ok | {:error, Qualification.probe_error()}
  def probe(probe, internals), do: Qualification.probe(__MODULE__, probe, internals)

  # The layout DescrWalk, closed_map/2, map_view/1, key_kinds/1 and
  # expand/1 read (audit-1.20.4.md rows 2-8 and the encoding rows).
  @impl Qualification
  @spec encoding_checks(module()) :: Qualification.checks()
  def encoding_checks(d) do
    int = d.integer()
    ok = d.atom([:ok])
    atom_top = d.atom()
    empty_list_bit = DescrWalk.bit_empty_list()

    [
      bitmap:
        Enum.all?(DescrWalk.bit_kinds(), fn {kind, bit} ->
          apply(d, kind, []) == %{bitmap: bit}
        end) and
          d.empty_list() == %{bitmap: empty_list_bit},
      atom_union: match?(%{atom: {:union, _}}, ok) and Qualification.atom_set(ok) == [:ok],
      atom_negation:
        match?(%{atom: {:negation, _}}, d.difference(atom_top, ok)) and
          Qualification.atom_set(d.difference(atom_top, ok)) == [:ok],
      closed_tuple: Qualification.tuple_line?(d, d.tuple([ok]), :closed, ok),
      open_tuple: Qualification.tuple_line?(d, d.open_tuple([ok]), :open, ok),
      optional_marker: d.if_set(int) == Map.put(int, :optional, 1),
      closed_map:
        map_line?(d, d.closed_map([{:a, d.if_set(int)}, {:b, int}, {[:binary], atom_top}]), int),
      bitstring_domain:
        d.to_domain_keys(d.bitstring_no_binary()) == [:bitstring] and
          domain_names(d, d.closed_map([{[:bitstring], int}])) == [:bitstring],
      open_map: match?([{[{_, :open, []}], []}], d.bdd_to_dnf(d.open_map().map)),
      list:
        Qualification.list_line?(d, d.non_empty_list(int, d.empty_list()), int, d.empty_list()),
      fun: Qualification.whole_fun?(d.fun()),
      dynamic: d.dynamic(int) == %{dynamic: int},
      term: d.term() == :term,
      none: d.none() == %{},
      # expand/1 builds term() from the kinds' top types.
      term_expansion:
        Enum.sort(Map.keys(term_parts(d))) == [:atom, :bitmap, :fun, :list, :map, :tuple] and
          d.equal?(term_parts(d), d.term()),
      # No recursive nodes: this adapter never expands one.
      no_recursive_nodes:
        not function_exported?(d, :recursive, 1) and not function_exported?(d, :unfold, 1)
    ]
  end

  # One literal {hash, [binary: domain], [a: optional int, b: int]}, the
  # domain value carrying the not_set() marker.
  defp map_line?(d, %{map: bdd}, int) do
    case d.bdd_to_dnf(bdd) do
      [{[{_hash, [binary: domain], [a: a, b: b]}], []}] ->
        optional?(domain) and d.equal?(strip(domain), d.atom()) and optional?(a) and
          d.equal?(strip(a), int) and not optional?(b) and d.equal?(b, int)

      _other ->
        false
    end
  end

  defp map_line?(_d, _descr, _int), do: false

  defp domain_names(d, %{map: bdd}) do
    case d.bdd_to_dnf(bdd) do
      [{[{_hash, domains, []}], []}] when is_list(domains) -> Keyword.keys(domains)
      _other -> :unexpected
    end
  end

  @impl Qualification
  @spec semantic_checks(module()) :: Qualification.checks()
  def semantic_checks(d) do
    int = d.integer()
    dyn_int = d.dynamic(int)

    [
      fun_contravariance:
        d.subtype?(d.fun([d.atom()], int), d.fun([d.atom([:a])], int)) and
          not d.subtype?(d.fun([d.atom([:a])], int), d.fun([d.atom()], int)),
      optional_field:
        d.subtype?(
          d.closed_map([{:a, int}]),
          d.closed_map([{:a, d.if_set(int)}, {[:atom], d.term()}])
        ) and not d.subtype?(d.closed_map([]), d.closed_map([{:a, int}])),
      gradual_bounds:
        d.equal?(d.upper_bound(dyn_int), int) and d.empty?(d.lower_bound(dyn_int)) and
          d.gradual?(dyn_int) and not d.gradual?(int),
      set_operations:
        d.disjoint?(int, d.atom()) and d.empty?(d.none()) and
          d.empty?(d.intersection(int, d.atom())) and
          d.equal?(d.union(int, d.float()), d.union(d.float(), int)),
      domain_keys: Enum.sort(d.to_domain_keys(d.union(d.binary(), int))) == [:binary, :integer],
      atom_fetch: Qualification.finite_atoms(d.atom_fetch(d.atom([:b, :a]))) == [:a, :b],
      quoted_dynamic:
        d.to_quoted_string(dyn_int, skip_dynamic_for_indivisible: false) == "dynamic(integer())"
    ]
  end

  ## Checker chunk

  @impl SpecLint.Compiler
  @spec qualified_checker_version() :: :elixir_checker_v8
  def qualified_checker_version, do: @checker_version

  @impl SpecLint.Compiler
  @spec decode_checker_chunk(binary()) ::
          {:ok, SpecLint.Compiler.chunk()} | {:error, SpecLint.Compiler.chunk_error()}
  def decode_checker_chunk(bytes) when is_binary(bytes),
    do: decode_checker_chunk(bytes, Qualification.running_checker_version())

  @doc """
  Decodes an `ExCk` chunk as `decode_checker_chunk/1` does, for a running
  compiler that writes `running` chunks; only `:elixir_checker_v8` chunks
  under a compiler that writes them are accepted.
  """
  @spec decode_checker_chunk(binary(), atom()) ::
          {:ok, SpecLint.Compiler.chunk()} | {:error, SpecLint.Compiler.chunk_error()}
  def decode_checker_chunk(bytes, running) when is_binary(bytes) and is_atom(running),
    do: Qualification.decode_checker_chunk(bytes, running, @checker_version)

  @impl SpecLint.Compiler
  @spec max_clauses() :: 16
  def max_clauses, do: @max_clauses

  @impl SpecLint.Compiler
  @spec pattern_diagnostics(module(), String.t() | nil, keyword(), [tuple()]) ::
          {:ok, [SpecLint.Compiler.pattern_diagnostic()]} | {:error, term()}
  defdelegate pattern_diagnostics(module, file, attributes, definitions), to: Qualification

  ## Application

  # Copy of Module.Types.Apply.apply_infer/2 (Elixir 1.20.4). It differs
  # from the 1.21 copy only in the union function; keep the clause order,
  # the reverse accumulation and the reduce direction: they determine the
  # exact union term the compiler builds.
  @impl SpecLint.Compiler
  @spec apply_infer([SpecLint.Compiler.clause()], [SpecLint.Compiler.descr()]) ::
          SpecLint.Compiler.application()
  def apply_infer(clauses, args_types) do
    case apply_clauses(clauses, args_types, 0, 0, [], []) do
      {0, [], []} ->
        :error

      {count, used, _returns} when count > @max_clauses ->
        {used, Descr.dynamic()}

      {_count, used, returns} ->
        {used, returns |> Enum.reduce(&union/2) |> Descr.dynamic()}
    end
  end

  defp apply_clauses([{expected, return} | clauses], args_types, index, count, used, returns) do
    if zip_not_disjoint?(args_types, expected) do
      apply_clauses(clauses, args_types, index + 1, count + 1, [index | used], [return | returns])
    else
      apply_clauses(clauses, args_types, index + 1, count, used, returns)
    end
  end

  defp apply_clauses([], _args_types, _index, count, used, returns) do
    {count, used, returns}
  end

  defp zip_not_disjoint?([actual | actuals], [expected | expecteds]) do
    not Descr.disjoint?(actual, expected) and zip_not_disjoint?(actuals, expecteds)
  end

  defp zip_not_disjoint?([], []), do: true

  ## Descr operations

  @impl SpecLint.Compiler
  @spec none() :: SpecLint.Compiler.descr()
  defdelegate none, to: Descr

  @impl SpecLint.Compiler
  @spec term() :: SpecLint.Compiler.descr()
  defdelegate term, to: Descr

  @impl SpecLint.Compiler
  @spec dynamic() :: SpecLint.Compiler.descr()
  defdelegate dynamic, to: Descr

  @impl SpecLint.Compiler
  @spec dynamic(SpecLint.Compiler.descr()) :: SpecLint.Compiler.descr()
  defdelegate dynamic(descr), to: Descr

  @impl SpecLint.Compiler
  @spec atom() :: SpecLint.Compiler.descr()
  defdelegate atom, to: Descr

  @impl SpecLint.Compiler
  @spec atom([atom()]) :: SpecLint.Compiler.descr()
  defdelegate atom(atoms), to: Descr

  @impl SpecLint.Compiler
  @spec integer() :: SpecLint.Compiler.descr()
  defdelegate integer, to: Descr

  @impl SpecLint.Compiler
  @spec float() :: SpecLint.Compiler.descr()
  defdelegate float, to: Descr

  @impl SpecLint.Compiler
  @spec binary() :: SpecLint.Compiler.descr()
  defdelegate binary, to: Descr

  @impl SpecLint.Compiler
  @spec bitstring() :: SpecLint.Compiler.descr()
  defdelegate bitstring, to: Descr

  @impl SpecLint.Compiler
  @spec bitstring_no_binary() :: SpecLint.Compiler.descr()
  defdelegate bitstring_no_binary, to: Descr

  @impl SpecLint.Compiler
  @spec pid() :: SpecLint.Compiler.descr()
  defdelegate pid, to: Descr

  @impl SpecLint.Compiler
  @spec port() :: SpecLint.Compiler.descr()
  defdelegate port, to: Descr

  @impl SpecLint.Compiler
  @spec reference() :: SpecLint.Compiler.descr()
  defdelegate reference, to: Descr

  @impl SpecLint.Compiler
  @spec boolean() :: SpecLint.Compiler.descr()
  defdelegate boolean, to: Descr

  @impl SpecLint.Compiler
  @spec empty_list() :: SpecLint.Compiler.descr()
  defdelegate empty_list, to: Descr

  @impl SpecLint.Compiler
  @spec list(SpecLint.Compiler.descr()) :: SpecLint.Compiler.descr()
  defdelegate list(elem), to: Descr

  @impl SpecLint.Compiler
  @spec non_empty_list(SpecLint.Compiler.descr(), SpecLint.Compiler.descr()) ::
          SpecLint.Compiler.descr()
  defdelegate non_empty_list(elem, tail), to: Descr

  @impl SpecLint.Compiler
  @spec tuple() :: SpecLint.Compiler.descr()
  defdelegate tuple, to: Descr

  @impl SpecLint.Compiler
  @spec tuple([SpecLint.Compiler.descr()]) :: SpecLint.Compiler.descr()
  defdelegate tuple(elems), to: Descr

  @impl SpecLint.Compiler
  @spec open_tuple([SpecLint.Compiler.descr()]) :: SpecLint.Compiler.descr()
  defdelegate open_tuple(elems), to: Descr

  @impl SpecLint.Compiler
  @spec empty_map() :: SpecLint.Compiler.descr()
  defdelegate empty_map, to: Descr

  @impl SpecLint.Compiler
  @spec open_map() :: SpecLint.Compiler.descr()
  defdelegate open_map, to: Descr

  @impl SpecLint.Compiler
  @spec fun() :: SpecLint.Compiler.descr()
  defdelegate fun, to: Descr

  @impl SpecLint.Compiler
  @spec fun(arity()) :: SpecLint.Compiler.descr()
  defdelegate fun(arity), to: Descr

  @impl SpecLint.Compiler
  @spec fun([SpecLint.Compiler.descr()], SpecLint.Compiler.descr()) :: SpecLint.Compiler.descr()
  defdelegate fun(args, return), to: Descr

  # Optional fields carry the not_set() marker (if_set/1); key domains are
  # named as this line names them.
  @impl SpecLint.Compiler
  @spec closed_map([SpecLint.Compiler.map_field()], [SpecLint.Compiler.map_domain()]) ::
          SpecLint.Compiler.descr()
  def closed_map(fields, domains) do
    pairs =
      for {key, value, optional?} <- fields,
          do: {key, if(optional?, do: if_set(value), else: value)}

    domain_pairs = for {kinds, value} <- domains, do: {Enum.map(kinds, &domain_name/1), value}
    Descr.closed_map(pairs ++ domain_pairs)
  end

  defp if_set(value), do: :erlang.apply(Descr, :if_set, [value])

  defp domain_name(:bitstring_no_binary), do: :bitstring
  defp domain_name(kind), do: kind

  defp key_kind(:bitstring), do: :bitstring_no_binary
  defp key_kind(kind), do: kind

  @impl SpecLint.Compiler
  @spec union(SpecLint.Compiler.descr(), SpecLint.Compiler.descr()) :: SpecLint.Compiler.descr()
  def union(left, right), do: :erlang.apply(Descr, :union, [left, right])

  @impl SpecLint.Compiler
  @spec intersection(SpecLint.Compiler.descr(), SpecLint.Compiler.descr()) ::
          SpecLint.Compiler.descr()
  def intersection(left, right), do: :erlang.apply(Descr, :intersection, [left, right])

  @impl SpecLint.Compiler
  @spec difference(SpecLint.Compiler.descr(), SpecLint.Compiler.descr()) ::
          SpecLint.Compiler.descr()
  def difference(left, right), do: :erlang.apply(Descr, :difference, [left, right])

  @impl SpecLint.Compiler
  @spec subtype?(SpecLint.Compiler.descr(), SpecLint.Compiler.descr()) :: boolean()
  defdelegate subtype?(left, right), to: Descr

  @impl SpecLint.Compiler
  @spec disjoint?(SpecLint.Compiler.descr(), SpecLint.Compiler.descr()) :: boolean()
  defdelegate disjoint?(left, right), to: Descr

  @impl SpecLint.Compiler
  @spec empty?(SpecLint.Compiler.descr()) :: boolean()
  defdelegate empty?(descr), to: Descr

  @impl SpecLint.Compiler
  @spec equal?(SpecLint.Compiler.descr(), SpecLint.Compiler.descr()) :: boolean()
  defdelegate equal?(left, right), to: Descr

  @impl SpecLint.Compiler
  @spec gradual?(SpecLint.Compiler.descr()) :: boolean()
  defdelegate gradual?(descr), to: Descr

  @impl SpecLint.Compiler
  @spec upper_bound(SpecLint.Compiler.descr()) :: SpecLint.Compiler.descr()
  defdelegate upper_bound(descr), to: Descr

  @impl SpecLint.Compiler
  @spec lower_bound(SpecLint.Compiler.descr()) :: SpecLint.Compiler.descr()
  defdelegate lower_bound(descr), to: Descr

  @impl SpecLint.Compiler
  @spec to_string(SpecLint.Compiler.descr()) :: String.t()
  def to_string(descr), do: DescrWalk.to_string(__MODULE__, descr)

  @impl SpecLint.Compiler
  @spec atom_fetch(SpecLint.Compiler.descr()) ::
          {:finite, [atom()]} | {:infinite, [atom()]} | :error
  defdelegate atom_fetch(descr), to: Descr

  # Descr.to_domain_keys/1 skips a finite atom component, because the
  # compiler's callers split finite atoms out first. Reporting :atom for it
  # keeps the kinds an upper bound of the key. This line names the domain of
  # bitstrings that are not binaries :bitstring.
  @impl SpecLint.Compiler
  @spec key_kinds(SpecLint.Compiler.descr()) :: [SpecLint.Compiler.key_kind()]
  def key_kinds(descr) do
    atoms? = not Descr.empty?(intersection(descr, Descr.atom()))

    descr
    |> Descr.to_domain_keys()
    |> Enum.map(&key_kind/1)
    |> Enum.concat(if atoms?, do: [:atom], else: [])
    |> Enum.filter(&(&1 in @key_kinds))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @impl SpecLint.Compiler
  @spec key_kind_descr(SpecLint.Compiler.key_kind()) :: SpecLint.Compiler.descr()
  def key_kind_descr(:atom), do: Descr.atom()
  def key_kind_descr(:binary), do: Descr.binary()
  def key_kind_descr(:bitstring_no_binary), do: Descr.bitstring_no_binary()
  def key_kind_descr(:float), do: Descr.float()
  def key_kind_descr(:fun), do: Descr.fun()
  def key_kind_descr(:integer), do: Descr.integer()
  def key_kind_descr(:map), do: Descr.open_map()
  def key_kind_descr(:pid), do: Descr.pid()
  def key_kind_descr(:port), do: Descr.port()
  def key_kind_descr(:reference), do: Descr.reference()
  def key_kind_descr(:tuple), do: Descr.tuple()

  def key_kind_descr(:list),
    do: union(Descr.empty_list(), Descr.non_empty_list(Descr.term(), Descr.term()))

  @impl SpecLint.Compiler
  @spec components(SpecLint.Compiler.descr()) :: [SpecLint.Compiler.component()]
  def components(descr), do: DescrWalk.components(__MODULE__, descr)

  # Structural, not semantic (DESIGN.md section 9). This line's descr terms
  # have no VM-specific values: no recursive nodes.
  @impl SpecLint.Compiler
  @spec canonical(SpecLint.Compiler.descr()) :: term()
  def canonical(descr), do: DescrWalk.canonical(__MODULE__, descr)

  ## DescrWalk hooks

  # `Descr.unfold/1` is private on this line; term() is expanded from the
  # top types of its kinds (the `:term_expansion` probe checks that the
  # result equals term()). Computed once per VM, from the running Descr.
  @impl DescrWalk
  @spec expand(SpecLint.Compiler.descr()) :: map()
  def expand(:term) do
    key = {__MODULE__, :term_parts}

    case :persistent_term.get(key, nil) do
      nil ->
        parts = term_parts(Descr)
        :persistent_term.put(key, parts)
        parts

      parts ->
        parts
    end
  end

  def expand(descr) when is_map(descr), do: descr

  defp term_parts(d) do
    [
      d.bitstring(),
      d.empty_list(),
      d.integer(),
      d.float(),
      d.pid(),
      d.port(),
      d.reference(),
      d.atom(),
      d.tuple(),
      d.open_map(),
      d.non_empty_list(d.term(), d.term()),
      d.fun()
    ]
    |> Enum.reduce(&d.union(&2, &1))
  end

  @impl DescrWalk
  @spec recursive_node?(term()) :: false
  def recursive_node?(_term), do: false

  # Map literals are {hash, :closed | :open | [{domain, value}], [{key,
  # value}]}; an optional field's value, and every domain value, carries the
  # not_set() marker, which is removed here.
  @impl DescrWalk
  @spec map_view(tuple()) :: SpecLint.Compiler.view()
  def map_view({_, tag, fields}) do
    fields = for {key, value} <- fields, do: {key, strip(value), optional?(value)}

    case tag do
      tag when tag in [:open, :closed] ->
        {:map, tag, fields, []}

      domains ->
        {:map, :closed, fields,
         for({kind, value} <- domains, do: {[key_kind(kind)], strip(value)})}
    end
  end

  defp optional?(%{optional: 1}), do: true
  defp optional?(_value), do: false

  defp strip(value) when is_map(value), do: Map.delete(value, :optional)
  defp strip(value), do: value
end
