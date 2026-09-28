defmodule SpecLint.Compiler.V121 do
  @moduledoc """
  Compiler adapter for Elixir 1.21 development builds with checker chunk
  `:elixir_checker_v10`.

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
    to_domain_keys: 1
  ]

  @impl true
  @spec preflight() :: {:ok, SpecLint.Compiler.capabilities()} | {:error, term()}
  def preflight do
    with :ok <- check_version(System.version()),
         :ok <- check_loaded(),
         :ok <- check_exports(),
         :ok <- check_checker_version(),
         :ok <- check_semantics() do
      {:ok,
       %{
         adapter: __MODULE__,
         elixir_version: System.version(),
         otp_release: System.otp_release(),
         checker_version: @checker_version,
         max_clauses: @max_clauses,
         signatures: true,
         body_hook: function_exported?(Module.Types, :warnings, 7)
       }}
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

  defp check_loaded do
    missing =
      Enum.reject([Module.Types.Descr, Module.Types.Apply, :elixir_erl], &Code.ensure_loaded?/1)

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
  defp running_checker_version, do: apply(:elixir_erl, :checker_version, [])

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
  def decode_checker_chunk(bytes) when is_binary(bytes) do
    expected = running_checker_version()

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

  @impl true
  @spec to_string(SpecLint.Compiler.descr()) :: String.t()
  def to_string(descr), do: Descr.to_quoted_string(descr, skip_dynamic_for_indivisible: false)

  @impl true
  @spec atom_fetch(SpecLint.Compiler.descr()) ::
          {:finite, [atom()]} | {:infinite, [atom()]} | :error
  def atom_fetch(descr), do: Descr.atom_fetch(descr)

  @impl true
  @spec key_kinds(SpecLint.Compiler.descr()) :: [SpecLint.Compiler.key_kind()]
  def key_kinds(descr) do
    descr
    |> Descr.to_domain_keys()
    |> Enum.filter(&(&1 in @key_kinds))
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
end
