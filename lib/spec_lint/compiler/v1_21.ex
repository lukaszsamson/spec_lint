defmodule SpecLint.Compiler.V121 do
  @moduledoc """
  Compiler adapter for Elixir 1.21 development builds with checker chunk
  `:elixir_checker_v10`.

  Qualified for the Elixir revisions in `qualified_revisions/0` only:
  `preflight/0` rejects any other build, even one writing the same checker
  chunk version, because `Descr` and `apply_infer/2` change between
  revisions without a chunk version bump.

  This is the only module in SpecLint that calls `Module.Types.Descr` or
  `:elixir_erl`. `apply_infer/2` is a line-by-line copy of the private
  `Module.Types.Apply.apply_infer/2` of the qualified revision, including its
  clause cutoff; differential tests compare it with the compiler's own
  application through `Module.Types.Apply.remote_apply/7`.
  """

  @behaviour SpecLint.Compiler

  alias Module.Types.Descr

  # Mirrors Module.Types.Apply @max_clauses.
  @max_clauses 16
  @checker_version :elixir_checker_v10
  @version_requirement "~> 1.21.0-dev"
  # Elixir revisions (short SHA, `System.build_info()[:revision]`) against
  # which the apply_infer/2 copy and the map encoding were qualified.
  @qualified_revisions ["c24c235"]

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
    opt_union: 2,
    opt_intersection: 2,
    opt_difference: 2,
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
    bdd_to_dnf: 1,
    unfold: 1
  ]

  @impl true
  @spec preflight() :: {:ok, SpecLint.Compiler.capabilities()} | {:error, term()}
  def preflight do
    version = System.version()
    revision = System.build_info()[:revision]

    with :ok <- check_build(version, revision),
         :ok <- check_loaded(),
         :ok <- check_exports(),
         :ok <- check_checker_version(),
         :ok <- check_semantics() do
      {:ok,
       %{
         adapter: __MODULE__,
         adapter_id: "#{version}+#{revision}",
         elixir_version: version,
         revision: revision,
         otp_release: System.otp_release(),
         checker_version: @checker_version,
         max_clauses: @max_clauses,
         signatures: true,
         # check_loaded/0 loaded Module.Types; function_exported?/3 does not.
         body_hook: function_exported?(Module.Types, :warnings, 7)
       }}
    end
  end

  @doc "The Elixir revisions (short commit SHAs) this adapter is qualified for."
  @spec qualified_revisions() :: [String.t(), ...]
  def qualified_revisions, do: @qualified_revisions

  @doc """
  Checks an Elixir version and build revision against this adapter's
  qualification. Used by `preflight/0` with the running build's values.
  """
  @spec check_build(String.t(), String.t() | nil) ::
          :ok
          | {:error, {:unsupported_elixir, String.t(), String.t()}}
          | {:error, {:unqualified_revision, String.t() | nil, [String.t()]}}
  def check_build(version, revision) do
    with :ok <- check_version(version) do
      check_revision(revision)
    end
  end

  defp check_version(version) do
    case Version.parse(version) do
      {:ok, parsed} ->
        if Version.match?(parsed, @version_requirement, allow_pre: true),
          do: :ok,
          else: {:error, {:unsupported_elixir, version, @version_requirement}}

      :error ->
        {:error, {:unsupported_elixir, version, @version_requirement}}
    end
  end

  defp check_revision(revision) when is_binary(revision) and byte_size(revision) >= 7 do
    if String.slice(revision, 0, 7) in @qualified_revisions,
      do: :ok,
      else: {:error, {:unqualified_revision, revision, @qualified_revisions}}
  end

  defp check_revision(revision),
    do: {:error, {:unqualified_revision, revision, @qualified_revisions}}

  defp check_loaded do
    modules = [Module.Types, Module.Types.Descr, Module.Types.Apply, :elixir_erl]
    missing = Enum.reject(modules, &Code.ensure_loaded?/1)

    if missing == [], do: :ok, else: {:error, {:missing_compiler_modules, missing}}
  end

  defp check_exports do
    missing = Enum.reject(@required_descr, fn {f, a} -> function_exported?(Descr, f, a) end)

    cond do
      missing != [] -> {:error, {:missing_descr_functions, missing}}
      not function_exported?(:elixir_erl, :checker_version, 0) -> {:error, :no_checker_version}
      true -> :ok
    end
  end

  defp check_checker_version do
    case running_checker_version() do
      @checker_version -> :ok
      other -> {:error, {:unsupported_checker_version, other, @checker_version}}
    end
  end

  # The checker version is a property of the running compiler, not of the
  # Elixir build SpecLint was analysed against, so it is read dynamically.
  # An apply keeps Dialyzer from specialising the result on the checker
  # version of the Elixir this was built with. `:erlang.apply/3` rather than
  # `Kernel.apply/3`: the arguments are known but the value must stay open.
  defp running_checker_version, do: :erlang.apply(:elixir_erl, :checker_version, [])

  # Semantic probes: function contravariance and the map field encoding, both
  # of which SpecLint relies on and which have changed in the past.
  defp check_semantics do
    contravariant? =
      Descr.subtype?(
        Descr.fun([Descr.atom()], Descr.integer()),
        Descr.fun([Descr.atom([:a])], Descr.integer())
      )

    map_ok? =
      Descr.subtype?(
        Descr.closed_map([{:a, {Descr.integer(), false}}]),
        closed_map([{:a, Descr.integer(), true}], [{[:atom], Descr.term()}])
      )

    if contravariant? and map_ok?,
      do: :ok,
      else: {:error, {:descr_probe_failed, contravariant?: contravariant?, map: map_ok?}}
  rescue
    error -> {:error, {:descr_probe_failed, Exception.message(error)}}
  end

  @impl true
  @spec qualified_checker_version() :: :elixir_checker_v10
  def qualified_checker_version, do: @checker_version

  @impl true
  @spec decode_checker_chunk(binary()) ::
          {:ok, SpecLint.Compiler.chunk()} | {:error, SpecLint.Compiler.chunk_error()}
  def decode_checker_chunk(bytes) when is_binary(bytes),
    do: decode_checker_chunk(bytes, running_checker_version())

  @doc """
  Decodes an `ExCk` chunk as `decode_checker_chunk/1` does, for a running
  compiler that writes `running` chunks. A chunk is accepted only when its
  version equals `running` and `running` is the version this adapter is
  qualified for; a compiler with another chunk version is never analysed
  with this adapter's copy of the application rule.
  """
  @spec decode_checker_chunk(binary(), atom()) ::
          {:ok, SpecLint.Compiler.chunk()} | {:error, SpecLint.Compiler.chunk_error()}
  def decode_checker_chunk(bytes, running) when is_binary(bytes) and is_atom(running) do
    if running == @checker_version do
      decode_qualified(bytes, running)
    else
      {:error, {:unqualified_checker_version, running, @checker_version}}
    end
  end

  defp decode_qualified(bytes, expected) do
    case decode_term(bytes) do
      {:ok, {^expected, %{exports: exports} = contents}} when is_list(exports) ->
        {:ok,
         %{
           version: expected,
           mode: Map.get(contents, :mode, :elixir),
           exports: Map.new(exports, &normalize_export/1)
         }}

      {:ok, {version, _contents}} when version != expected ->
        {:error, {:checker_version_mismatch, version, expected}}

      _ ->
        {:error, :malformed_chunk}
    end
  end

  # Checker chunks come from local build artifacts and contain atoms (module
  # names) that may not exist yet in this VM, so :safe cannot be used; the
  # compiler's own reader (Module.ParallelChecker) decodes the same way.
  defp decode_term(bytes) do
    {:ok, :erlang.binary_to_term(bytes)}
  rescue
    ArgumentError -> :error
  end

  defp normalize_export({{fun, arity}, info}) when is_map(info) do
    sig =
      case info do
        %{sig: {kind, _, _} = sig} when kind in [:infer, :strong] -> sig
        _ -> :none
      end

    {{fun, arity}, %{sig: sig, deprecated: Map.get(info, :deprecated)}}
  end

  @impl true
  @spec max_clauses() :: 16
  def max_clauses, do: @max_clauses

  # Copy of Module.Types.Apply.apply_infer/2 (Elixir c24c235). Keep the
  # clause order, the reverse accumulation and the reduce direction: they
  # determine the exact union term the compiler builds.
  @impl true
  @spec apply_infer([SpecLint.Compiler.clause()], [SpecLint.Compiler.descr()]) ::
          SpecLint.Compiler.application()
  def apply_infer(clauses, args_types) do
    case apply_clauses(clauses, args_types, 0, 0, [], []) do
      {0, [], []} ->
        :error

      {count, used, _returns} when count > @max_clauses ->
        {used, Descr.dynamic()}

      {_count, used, returns} ->
        {used, returns |> Enum.reduce(&Descr.opt_union/2) |> Descr.dynamic()}
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

  @impl true
  @spec none() :: SpecLint.Compiler.descr()
  def none, do: Descr.none()

  @impl true
  @spec term() :: SpecLint.Compiler.descr()
  def term, do: Descr.term()

  @impl true
  @spec dynamic() :: SpecLint.Compiler.descr()
  def dynamic, do: Descr.dynamic()

  @impl true
  @spec dynamic(SpecLint.Compiler.descr()) :: SpecLint.Compiler.descr()
  def dynamic(descr), do: Descr.dynamic(descr)

  @impl true
  @spec atom() :: SpecLint.Compiler.descr()
  def atom, do: Descr.atom()

  @impl true
  @spec atom([atom()]) :: SpecLint.Compiler.descr()
  def atom(atoms), do: Descr.atom(atoms)

  @impl true
  @spec integer() :: SpecLint.Compiler.descr()
  def integer, do: Descr.integer()

  @impl true
  @spec float() :: SpecLint.Compiler.descr()
  def float, do: Descr.float()

  @impl true
  @spec binary() :: SpecLint.Compiler.descr()
  def binary, do: Descr.binary()

  @impl true
  @spec bitstring() :: SpecLint.Compiler.descr()
  def bitstring, do: Descr.bitstring()

  @impl true
  @spec bitstring_no_binary() :: SpecLint.Compiler.descr()
  def bitstring_no_binary, do: Descr.bitstring_no_binary()

  @impl true
  @spec pid() :: SpecLint.Compiler.descr()
  def pid, do: Descr.pid()

  @impl true
  @spec port() :: SpecLint.Compiler.descr()
  def port, do: Descr.port()

  @impl true
  @spec reference() :: SpecLint.Compiler.descr()
  def reference, do: Descr.reference()

  @impl true
  @spec boolean() :: SpecLint.Compiler.descr()
  def boolean, do: Descr.boolean()

  @impl true
  @spec empty_list() :: SpecLint.Compiler.descr()
  def empty_list, do: Descr.empty_list()

  @impl true
  @spec list(SpecLint.Compiler.descr()) :: SpecLint.Compiler.descr()
  def list(elem), do: Descr.list(elem)

  @impl true
  @spec non_empty_list(SpecLint.Compiler.descr(), SpecLint.Compiler.descr()) ::
          SpecLint.Compiler.descr()
  def non_empty_list(elem, tail), do: Descr.non_empty_list(elem, tail)

  @impl true
  @spec tuple() :: SpecLint.Compiler.descr()
  def tuple, do: Descr.tuple()

  @impl true
  @spec tuple([SpecLint.Compiler.descr()]) :: SpecLint.Compiler.descr()
  def tuple(elems), do: Descr.tuple(elems)

  @impl true
  @spec open_tuple([SpecLint.Compiler.descr()]) :: SpecLint.Compiler.descr()
  def open_tuple(elems), do: Descr.open_tuple(elems)

  @impl true
  @spec empty_map() :: SpecLint.Compiler.descr()
  def empty_map, do: Descr.empty_map()

  @impl true
  @spec open_map() :: SpecLint.Compiler.descr()
  def open_map, do: Descr.open_map()

  # The map pair encoding ({key, {value, optional?}} for atom keys and
  # {[kinds], value} for key domains) is specific to this revision.
  @impl true
  @spec closed_map([SpecLint.Compiler.map_field()], [SpecLint.Compiler.map_domain()]) ::
          SpecLint.Compiler.descr()
  def closed_map(fields, domains) do
    pairs = for {key, value, optional?} <- fields, do: {key, {value, optional?}}
    Descr.closed_map(pairs ++ domains)
  end

  @impl true
  @spec fun() :: SpecLint.Compiler.descr()
  def fun, do: Descr.fun()

  @impl true
  @spec fun(arity()) :: SpecLint.Compiler.descr()
  def fun(arity), do: Descr.fun(arity)

  @impl true
  @spec fun([SpecLint.Compiler.descr()], SpecLint.Compiler.descr()) :: SpecLint.Compiler.descr()
  def fun(args, return), do: Descr.fun(args, return)

  @impl true
  @spec union(SpecLint.Compiler.descr(), SpecLint.Compiler.descr()) :: SpecLint.Compiler.descr()
  def union(left, right), do: Descr.opt_union(left, right)

  @impl true
  @spec intersection(SpecLint.Compiler.descr(), SpecLint.Compiler.descr()) ::
          SpecLint.Compiler.descr()
  def intersection(left, right), do: Descr.opt_intersection(left, right)

  @impl true
  @spec difference(SpecLint.Compiler.descr(), SpecLint.Compiler.descr()) ::
          SpecLint.Compiler.descr()
  def difference(left, right), do: Descr.opt_difference(left, right)

  @impl true
  @spec subtype?(SpecLint.Compiler.descr(), SpecLint.Compiler.descr()) :: boolean()
  def subtype?(left, right), do: Descr.subtype?(left, right)

  @impl true
  @spec disjoint?(SpecLint.Compiler.descr(), SpecLint.Compiler.descr()) :: boolean()
  def disjoint?(left, right), do: Descr.disjoint?(left, right)

  @impl true
  @spec empty?(SpecLint.Compiler.descr()) :: boolean()
  def empty?(descr), do: Descr.empty?(descr)

  @impl true
  @spec equal?(SpecLint.Compiler.descr(), SpecLint.Compiler.descr()) :: boolean()
  def equal?(left, right), do: Descr.equal?(left, right)

  @impl true
  @spec gradual?(SpecLint.Compiler.descr()) :: boolean()
  def gradual?(descr), do: Descr.gradual?(descr)

  @impl true
  @spec upper_bound(SpecLint.Compiler.descr()) :: SpecLint.Compiler.descr()
  def upper_bound(descr), do: Descr.upper_bound(descr)

  @impl true
  @spec lower_bound(SpecLint.Compiler.descr()) :: SpecLint.Compiler.descr()
  def lower_bound(descr), do: Descr.lower_bound(descr)

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
  @impl true
  @spec to_string(SpecLint.Compiler.descr()) :: String.t()
  def to_string(descr) do
    cond do
      Descr.empty?(descr) -> "none()"
      Descr.gradual?(descr) -> quoted(descr)
      true -> canonical_or_complement(descr)
    end
  end

  defp quoted(descr), do: Descr.to_quoted_string(descr, skip_dynamic_for_indivisible: false)

  defp canonical_or_complement(descr) do
    complement = Descr.opt_difference(Descr.term(), descr)

    if Descr.empty?(complement) do
      "term()"
    else
      direct = normal_form_string(descr)
      negated = "not " <> parenthesise(normal_form_string(complement))
      if String.length(negated) < String.length(direct), do: negated, else: direct
    end
  end

  defp normal_form_string(descr) do
    static = descr |> unfold_node() |> Descr.unfold()
    rest = Map.drop(static, [:tuple, :map])

    rest_string = if Descr.empty?(rest), do: [], else: [quoted(rest)]

    lines =
      Enum.flat_map([:tuple, :map], fn kind ->
        case Map.get(static, kind) do
          nil -> []
          bdd -> bdd |> Descr.bdd_to_dnf() |> Enum.reverse() |> Enum.flat_map(&line(kind, &1))
        end
      end)

    case rest_string ++ Enum.uniq(lines) do
      [single] -> single
      pieces -> Enum.map_join(pieces, " or ", &parenthesise_and/1)
    end
  end

  defp parenthesise(string) do
    if String.contains?(string, [" or ", " and "]), do: "(" <> string <> ")", else: string
  end

  defp parenthesise_and(string) do
    if String.contains?(string, " and not "), do: "(" <> string <> ")", else: string
  end

  defp line(kind, {pos, negs}) do
    positives = if pos == [], do: [top_literal(kind)], else: pos
    pos_descr = positives |> Enum.map(&%{kind => &1}) |> Enum.reduce(&Descr.opt_intersection/2)
    live = Enum.reject(negs, &Descr.disjoint?(pos_descr, %{kind => &1}))
    line = Enum.reduce(live, pos_descr, &Descr.opt_difference(&2, %{kind => &1}))

    if Descr.empty?(line) do
      []
    else
      positive = Enum.map_join(positives, " and ", &literal_string(kind, &1))

      case Enum.map(live, &literal_string(kind, &1)) do
        [] -> [positive]
        [neg] -> [positive <> " and not " <> neg]
        negs -> [positive <> " and not (" <> Enum.join(negs, " or ") <> ")"]
      end
    end
  end

  defp literal_string(kind, literal), do: quoted(%{kind => literal})

  @impl true
  @spec atom_fetch(SpecLint.Compiler.descr()) ::
          {:finite, [atom()]} | {:infinite, [atom()]} | :error
  def atom_fetch(descr), do: Descr.atom_fetch(unfold_node(descr))

  # Recursive type nodes ({id, state, generator}) must be expanded before
  # functions that pattern match on the descr map.
  defp unfold_node({_id, _state, _generator} = node), do: Descr.unfold(node)
  defp unfold_node(descr), do: descr

  # Descr.to_domain_keys/1 skips a finite atom component, because the
  # compiler's callers split finite atoms out first. Reporting :atom for it
  # keeps the kinds an upper bound of the key.
  @impl true
  @spec key_kinds(SpecLint.Compiler.descr()) :: [SpecLint.Compiler.key_kind()]
  def key_kinds(descr) do
    atoms? = not Descr.empty?(Descr.opt_intersection(descr, Descr.atom()))

    descr
    |> Descr.to_domain_keys()
    |> Enum.concat(if atoms?, do: [:atom], else: [])
    |> Enum.filter(&(&1 in @key_kinds))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @impl true
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
    do: Descr.opt_union(Descr.empty_list(), Descr.non_empty_list(Descr.term(), Descr.term()))

  ## Components
  #
  # The walk below reads this revision's descr layout: a map of per-kind
  # parts (`bitmap`, `atom`, `tuple`, `map`, `list`, `fun`, `dynamic`),
  # atoms as `{:union | :negation, :sets}`, and tuples, maps and non-empty
  # lists as BDDs over literals `{hash, tag_or_head, elements_or_tail}`.

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

  @impl true
  @spec components(SpecLint.Compiler.descr()) :: [SpecLint.Compiler.component()]
  def components(descr) do
    static = descr |> unfold_node() |> Descr.upper_bound() |> Descr.unfold()
    bitmap = Map.get(static, :bitmap, 0)

    bit_components(bitmap) ++
      atom_components(Map.get(static, :atom)) ++
      bdd_components(:tuple, Map.get(static, :tuple)) ++
      bdd_components(:map, Map.get(static, :map)) ++
      list_components(Map.get(static, :list), Bitwise.band(bitmap, @bit_empty_list) != 0) ++
      fun_components(Map.get(static, :fun))
  end

  defp bit_components(bitmap) do
    for {kind, bit} <- @bit_kinds, Bitwise.band(bitmap, bit) != 0 do
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

  defp list_components(nil, false), do: []

  defp list_components(nil, true),
    do: [%{kind: :list, descr: %{bitmap: @bit_empty_list}, view: :empty_list}]

  defp list_components(bdd, empty?) do
    case bdd_components(:list, bdd) do
      [] ->
        list_components(nil, empty?)

      lines when empty? ->
        Enum.map(lines, &with_empty_list/1)

      lines ->
        lines
    end
  end

  defp with_empty_list(%{descr: descr, view: view} = component) do
    view =
      case view do
        {:list, element, tail, false} -> {:list, element, tail, true}
        other -> other
      end

    %{component | descr: Descr.opt_union(descr, %{bitmap: @bit_empty_list}), view: view}
  end

  defp bdd_components(_kind, nil), do: []

  defp bdd_components(kind, bdd) do
    bdd
    |> Descr.bdd_to_dnf()
    |> Enum.reverse()
    |> Enum.flat_map(fn {pos, negs} -> line_components(kind, pos, negs) end)
    |> Enum.uniq_by(& &1.descr)
  end

  defp line_components(kind, pos, negs) do
    positives = if pos == [], do: [top_literal(kind)], else: pos
    pos_descr = positives |> Enum.map(&%{kind => &1}) |> Enum.reduce(&Descr.opt_intersection/2)
    line = Enum.reduce(negs, pos_descr, &Descr.opt_difference(&2, %{kind => &1}))

    cond do
      Descr.empty?(line) ->
        []

      match?([_, _ | _], positives) ->
        [%{kind: kind, descr: line, view: {:unknown, kind, :intersection}}]

      true ->
        [literal] = positives
        live = Enum.reject(negs, &Descr.disjoint?(pos_descr, %{kind => &1}))
        eliminate(kind, literal, live, line)
    end
  end

  defp top_literal(:tuple), do: Descr.tuple().tuple
  defp top_literal(:map), do: Descr.open_map().map
  defp top_literal(:list), do: Descr.non_empty_list(Descr.term(), Descr.term()).list

  defp eliminate(kind, literal, [], _line),
    do: [%{kind: kind, descr: %{kind => literal}, view: literal_view(kind, literal)}]

  defp eliminate(:tuple, {_, :closed, elements}, negs, line) do
    size = length(elements)

    if Enum.all?(negs, &same_size_negation?(&1, size)) do
      negs
      |> Enum.reduce([elements], fn {_, _, neg_elements}, acc ->
        padded = neg_elements ++ List.duplicate(Descr.term(), size - length(neg_elements))
        Enum.flat_map(acc, &tuple_split(&1, padded))
      end)
      |> Enum.map(fn elements ->
        %{kind: :tuple, descr: Descr.tuple(elements), view: {:tuple, :closed, elements}}
      end)
    else
      [%{kind: :tuple, descr: line, view: {:unknown, :tuple, :negation}}]
    end
  end

  defp eliminate(kind, _literal, _negs, line),
    do: [%{kind: kind, descr: line, view: {:unknown, kind, :negation}}]

  defp same_size_negation?({_, :closed, neg_elements}, size), do: length(neg_elements) == size
  defp same_size_negation?({_, :open, neg_elements}, size), do: length(neg_elements) <= size
  defp same_size_negation?(_literal, _size), do: false

  # {t1..tn} and not {u1..un} is the union, over the first index i where a
  # value differs, of {t1 and u1, ..., ti - ui, t(i+1), ..., tn}.
  defp tuple_split(elements, neg_elements) do
    if Enum.any?(Enum.zip(elements, neg_elements), fn {t, u} -> Descr.disjoint?(t, u) end) do
      [elements]
    else
      pairs = Enum.zip(elements, neg_elements)

      for index <- 0..(length(pairs) - 1),
          line = tuple_split_line(pairs, index),
          not Enum.any?(line, &Descr.empty?/1),
          do: line
    end
  end

  defp tuple_split_line(pairs, index) do
    pairs
    |> Enum.with_index()
    |> Enum.map(fn
      {{t, u}, i} when i < index -> Descr.opt_intersection(t, u)
      {{t, u}, ^index} -> Descr.opt_difference(t, u)
      {{t, _u}, _i} -> t
    end)
  end

  defp literal_view(:tuple, {_, :open, []}), do: {:whole, :tuple}
  defp literal_view(:tuple, {_, tag, elements}), do: {:tuple, tag, elements}
  defp literal_view(:map, {_, :open, []}), do: {:whole, :map}

  defp literal_view(:map, {_, tag, fields}) do
    fields = for {key, {value, optional?}} <- fields, do: {key, value, optional?}

    case tag do
      tag when tag in [:open, :closed] -> {:map, tag, fields, []}
      domains -> {:map, :closed, fields, for({kind, value} <- domains, do: {[kind], value})}
    end
  end

  defp literal_view(:list, {_, element, tail}), do: {:list, element, tail, false}

  ## Canonical form
  #
  # This revision's descr terms are maps of per-kind parts whose values are
  # bitmaps, `:sets` (maps in version 2), BDD tuples and literal tuples
  # carrying `:erlang.phash2/1` hashes. `phash2` is portable, so the only
  # VM-specific values are recursive type nodes (`{reference, state,
  # generator}`), which inference does not produce today. They are unfolded
  # to a fixed depth and cut off with a marker. Maps are turned into sorted
  # key/value lists so the result does not depend on map iteration order.

  @canonical_node_depth 3

  @impl true
  @spec canonical(SpecLint.Compiler.descr()) :: term()
  def canonical(descr), do: canonical_term(descr, @canonical_node_depth)

  defp canonical_term({id, _state, generator} = node, depth)
       when is_reference(id) and is_function(generator, 1) do
    if depth == 0,
      do: :recursive_node,
      else: {:recursive_node, canonical_term(Descr.unfold(node), depth - 1)}
  end

  defp canonical_term(map, depth) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {canonical_term(key, depth), canonical_term(value, depth)} end)
    |> Enum.sort()
    |> then(&{:map, &1})
  end

  defp canonical_term(tuple, depth) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.map(&canonical_term(&1, depth)) |> List.to_tuple()
  end

  defp canonical_term([head | tail], depth),
    do: [canonical_term(head, depth) | canonical_term(tail, depth)]

  defp canonical_term(fun, _depth) when is_function(fun), do: :function
  defp canonical_term(ref, _depth) when is_reference(ref), do: :reference
  defp canonical_term(pid, _depth) when is_pid(pid) or is_port(pid), do: :process
  defp canonical_term(other, _depth), do: other
end
