# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2021 The Elixir Team
# SPDX-FileCopyrightText: 2012 Plataformatec
#
# Adapted from Elixir c24c235 / 648b2a9, lib/elixir/lib/module/types/apply.ex.
# Modified: adapter interface, qualified compiler checks, and surrounding operations;
# apply_infer/2 and its private helpers retain the upstream application rule.
# Source attribution and license: THIRD_PARTY_NOTICES.md and LICENSE.

defmodule SpecLint.Compiler.V121 do
  @moduledoc """
  Compiler adapter for Elixir 1.21 development builds with checker chunk
  `:elixir_checker_v10`.

  Qualified for the Elixir revisions in `qualified_revisions/0` only:
  `c24c235` (the fork revision SpecLint was developed on) and the upstream
  revision `648b2a9`. `preflight/0` rejects any other build, even one
  writing the same checker chunk version, because `Descr` and
  `apply_infer/2` change between revisions without a chunk version bump.
  The audit behind each revision is in `bench/corpus/toolchain/`
  (`audit-648b2a9.md`).

  Preflight (`SpecLint.Compiler.Qualification`) does not trust the
  revision alone. `System.build_info()` derives it from `git rev-parse
  HEAD`, which a modified checkout of a qualified commit also reports, so
  the first probe, `:compiler_identity`, compares the code of the pinned
  compiler modules (`SpecLint.Compiler.BuildIdentity`) with the digests
  recorded for the revision when it was qualified (`qualified_builds/0`).
  Then one capability probe per compiler internal SpecLint depends on
  (`capability_probes/0`) checks its interface and behaviour; the three
  `Module.Types.Descr` probes use this adapter's `required_descr/0`,
  `encoding_checks/1` and `semantic_checks/1`. `preflight/1` takes the
  internals to probe, so tests can substitute a missing or changed one.

  What is specific to this compiler line lives here: the set operations
  (`opt_union/2`, `opt_intersection/2`, `opt_difference/2`), the map
  field encoding (`{key, {value, optional?}}` and key domains
  `{[kind], value}` with the kind `:bitstring_no_binary`), `term()` and
  recursive nodes expanded by `Descr.unfold/1`, the chunk version and the
  `apply_infer/2` copy. The walk over the descr layout that is the same on
  every qualified line (components, printing, canonical form) is
  `SpecLint.Compiler.DescrWalk`. Functions that only this line's `Descr`
  exports are called through `:erlang.apply/3`, so that compiling
  SpecLint with the 1.20 compiler, and Dialyzer there, see no call to a
  function its `Descr` lacks.

  `apply_infer/2` is a line-by-line copy of the private
  `Module.Types.Apply.apply_infer/2` of the qualified revisions (identical
  in both), including its clause cutoff; differential tests and the
  `:apply_infer` probe compare it with the compiler's own application
  through `Module.Types.Apply.remote_apply/7`.
  """

  @behaviour SpecLint.Compiler
  @behaviour SpecLint.Compiler.Qualification
  @behaviour SpecLint.Compiler.DescrWalk

  alias Module.Types.Descr
  alias SpecLint.Compiler.{BuildIdentity, DescrWalk, Qualification}

  # Mirrors Module.Types.Apply @max_clauses.
  @max_clauses 16
  @checker_version :elixir_checker_v10
  @version_requirement "~> 1.21.0-dev"
  # Elixir revisions (short SHA, `System.build_info()[:revision]`) against
  # which the apply_infer/2 copy, the Descr encodings and every other
  # internal were qualified (bench/corpus/toolchain/audit-648b2a9.md).
  @qualified_revisions ["c24c235", "648b2a9"]

  # Per qualified revision, the code digests of the pinned compiler modules
  # (SpecLint.Compiler.BuildIdentity), printed by
  # bench/corpus/toolchain/pinned_digests.exs on the qualified build. They
  # do not depend on the build directory, the build date or the OTP 28
  # patch release (checked with 28.0, 28.3.1 and 28.5.0.1).
  @qualified_builds %{
    "c24c235" => %{
      "Elixir.Code.Typespec" =>
        "d6dd8c60af8e4d3599ef28c1c14e38c8baa2f8794ffb2952adf06f546dfed06f",
      "Elixir.Mix.Compilers.Elixir" =>
        "7f01011ee452d0cac06eaa0552d51095071618bc8e6e1b79906cd628e91b4b9c",
      "Elixir.Module.ParallelChecker" =>
        "55375aa973552ad8eba5c3e3064a9ee9c85079dd82d31d167f06dfecab716d6c",
      "Elixir.Module.Types" => "d14dea66c1d0a916d7299e56e2488fd6e2360606d608a2c9def43032c3fe1980",
      "Elixir.Module.Types.Apply" =>
        "0b5223def6854e4bd656431bc8b21551797509d6943e80296ae68a1cc44f6510",
      "Elixir.Module.Types.Descr" =>
        "ebf450ef3659653899af125bd8e41f24bdaa824971c15e546f135421ff03c817",
      "Elixir.Module.Types.Expr" =>
        "7240ffc26464d3adf60fec08366cdee9ed889f13658c6ef1cd0116855a502124",
      "Elixir.Module.Types.Helpers" =>
        "44657cd37cac8e2867987dfcad29cdc052ff247a7e0006fe2132b09e28620821",
      "Elixir.Module.Types.Of" =>
        "91c42c28367e1bb0b7965487cacd55ce85e71a49dcb820a729cf5fe1f92721e9",
      "Elixir.Module.Types.Pattern" =>
        "bc2052f074028743066220d54b0cea2dadccda4da0b21c31732c1c5524a1a4fa",
      "Elixir.Module.Types.Traverse" =>
        "57f39298439f71163f98321f21a51442f5d5ba56254181af9026ffbc5845d8b4",
      "elixir_def" => "2102e3fe40685a630cf2dcba979ffda4037faed7c5552a0afbf6cbc383689239",
      "elixir_erl" => "d47039dda4443fe734ec1fac8628fb35fee4c51ebc46824b11d6061d7d85537d",
      "elixir_overridable" => "395f60f7b9f57faea7e1bf2a5ad84286d2a0db09a27c2e8b65505f28de70e79a"
    },
    "648b2a9" => %{
      "Elixir.Code.Typespec" =>
        "d6dd8c60af8e4d3599ef28c1c14e38c8baa2f8794ffb2952adf06f546dfed06f",
      "Elixir.Mix.Compilers.Elixir" =>
        "7f01011ee452d0cac06eaa0552d51095071618bc8e6e1b79906cd628e91b4b9c",
      "Elixir.Module.ParallelChecker" =>
        "55375aa973552ad8eba5c3e3064a9ee9c85079dd82d31d167f06dfecab716d6c",
      "Elixir.Module.Types" => "d14dea66c1d0a916d7299e56e2488fd6e2360606d608a2c9def43032c3fe1980",
      "Elixir.Module.Types.Apply" =>
        "3ed319aab521246c3463a7bb65e8764c5854595360021aa7b0367f44994e2165",
      "Elixir.Module.Types.Descr" =>
        "ebf450ef3659653899af125bd8e41f24bdaa824971c15e546f135421ff03c817",
      "Elixir.Module.Types.Expr" =>
        "60ac61b00d8a1e2c7dade0d9c63baead252584c1466477e9267d8532cef12113",
      "Elixir.Module.Types.Helpers" =>
        "44657cd37cac8e2867987dfcad29cdc052ff247a7e0006fe2132b09e28620821",
      "Elixir.Module.Types.Of" =>
        "91c42c28367e1bb0b7965487cacd55ce85e71a49dcb820a729cf5fe1f92721e9",
      "Elixir.Module.Types.Pattern" =>
        "bc2052f074028743066220d54b0cea2dadccda4da0b21c31732c1c5524a1a4fa",
      "Elixir.Module.Types.Traverse" =>
        "57f39298439f71163f98321f21a51442f5d5ba56254181af9026ffbc5845d8b4",
      "elixir_def" => "2102e3fe40685a630cf2dcba979ffda4037faed7c5552a0afbf6cbc383689239",
      "elixir_erl" => "d47039dda4443fe734ec1fac8628fb35fee4c51ebc46824b11d6061d7d85537d",
      "elixir_overridable" => "395f60f7b9f57faea7e1bf2a5ad84286d2a0db09a27c2e8b65505f28de70e79a"
    }
  }

  # Map key domain kinds, as this line names them.
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
    unfold: 1,
    recursive: 1
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
  `preflight/0` against `internals` (`SpecLint.Compiler.Qualification.preflight/2`):
  checks the build revision, that every internal module loads, and runs
  every capability probe in `capability_probes/0`. The first failure is
  returned as `{:error, {:capability_probe_failed, probe, detail}}`; a
  probe that raises fails with the exception message.
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
  @spec recursive_types?() :: true
  def recursive_types?, do: true

  @impl Qualification
  @spec nominal_types?() :: true
  def nominal_types?, do: true

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

  # The layout DescrWalk, closed_map/2, map_view/1 and canonical/1 read.
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
        match?(%{atom: {:negation, _}}, d.opt_difference(atom_top, ok)) and
          Qualification.atom_set(d.opt_difference(atom_top, ok)) == [:ok],
      closed_tuple: Qualification.tuple_line?(d, d.tuple([ok]), :closed, ok),
      open_tuple: Qualification.tuple_line?(d, d.open_tuple([ok]), :open, ok),
      closed_map: map_line?(d, d.closed_map([{:a, {int, true}}, {[:binary], atom_top}]), int),
      open_map: match?([{[{_, :open, []}], []}], d.bdd_to_dnf(d.open_map().map)),
      list:
        Qualification.list_line?(d, d.non_empty_list(int, d.empty_list()), int, d.empty_list()),
      fun: Qualification.whole_fun?(d.fun()),
      dynamic: d.dynamic(int) == %{dynamic: int},
      term: d.term() == :term,
      none: d.none() == %{},
      # unfold/1 expands term() and recursive nodes, and is the identity
      # on every other type.
      unfold: d.unfold(int) == int and d.equal?(d.unfold(d.term()), d.term()),
      recursive_node: recursive_node_probe?(d)
    ]
  end

  # Recursive type nodes are {reference, state, generator} (recursive_node?/1
  # and expand/1 match that layout) and unfold to their generator's result.
  defp recursive_node_probe?(d) do
    int = d.integer()

    case d.recursive(%{t: fn _recur -> int end}) do
      %{t: {id, state, generator} = node}
      when is_reference(id) and is_map(state) and is_function(generator, 1) ->
        d.equal?(d.unfold(node), int)

      _other ->
        false
    end
  end

  defp map_line?(d, %{map: bdd}, int) do
    case d.bdd_to_dnf(bdd) do
      [{[{_hash, [binary: domain], [a: {value, true}]}], []}] ->
        d.equal?(domain, d.atom()) and d.equal?(value, int)

      _other ->
        false
    end
  end

  defp map_line?(_d, _descr, _int), do: false

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
          d.closed_map([{:a, {int, false}}]),
          d.closed_map([{:a, {int, true}}, {[:atom], d.term()}])
        ) and not d.subtype?(d.closed_map([]), d.closed_map([{:a, {int, false}}])),
      gradual_bounds:
        d.equal?(d.upper_bound(dyn_int), int) and d.empty?(d.lower_bound(dyn_int)) and
          d.gradual?(dyn_int) and not d.gradual?(int),
      set_operations:
        d.disjoint?(int, d.atom()) and d.empty?(d.none()) and
          d.empty?(d.opt_intersection(int, d.atom())) and
          d.equal?(d.opt_union(int, d.float()), d.opt_union(d.float(), int)),
      domain_keys:
        Enum.sort(d.to_domain_keys(d.opt_union(d.binary(), int))) == [:binary, :integer],
      atom_fetch: Qualification.finite_atoms(d.atom_fetch(d.atom([:b, :a]))) == [:a, :b],
      quoted_dynamic:
        d.to_quoted_string(dyn_int, skip_dynamic_for_indivisible: false) == "dynamic(integer())"
    ]
  end

  ## Checker chunk

  @impl SpecLint.Compiler
  @spec qualified_checker_version() :: :elixir_checker_v10
  def qualified_checker_version, do: @checker_version

  @impl SpecLint.Compiler
  @spec decode_checker_chunk(binary()) ::
          {:ok, SpecLint.Compiler.chunk()} | {:error, SpecLint.Compiler.chunk_error()}
  def decode_checker_chunk(bytes) when is_binary(bytes),
    do: decode_checker_chunk(bytes, Qualification.running_checker_version())

  @doc """
  Decodes an `ExCk` chunk as `decode_checker_chunk/1` does, for a running
  compiler that writes `running` chunks. A chunk is accepted only when its
  version equals `running` and `running` is the version this adapter is
  qualified for; a compiler with another chunk version is never analysed
  with this adapter's copy of the application rule.
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

  # Copy of Module.Types.Apply.apply_infer/2 (Elixir c24c235, unchanged in
  # 648b2a9). Keep the clause order, the reverse accumulation and the
  # reduce direction: they determine the exact union term the compiler
  # builds.
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

  # The map pair encoding ({key, {value, optional?}} for atom keys and
  # {[kinds], value} for key domains) is specific to this compiler line.
  @impl SpecLint.Compiler
  @spec closed_map([SpecLint.Compiler.map_field()], [SpecLint.Compiler.map_domain()]) ::
          SpecLint.Compiler.descr()
  def closed_map(fields, domains) do
    pairs = for {key, value, optional?} <- fields, do: {key, {value, optional?}}
    Descr.closed_map(pairs ++ domains)
  end

  @impl SpecLint.Compiler
  @spec fun() :: SpecLint.Compiler.descr()
  defdelegate fun, to: Descr

  @impl SpecLint.Compiler
  @spec fun(arity()) :: SpecLint.Compiler.descr()
  defdelegate fun(arity), to: Descr

  @impl SpecLint.Compiler
  @spec fun([SpecLint.Compiler.descr()], SpecLint.Compiler.descr()) :: SpecLint.Compiler.descr()
  defdelegate fun(args, return), to: Descr

  @impl SpecLint.Compiler
  @spec union(SpecLint.Compiler.descr(), SpecLint.Compiler.descr()) :: SpecLint.Compiler.descr()
  def union(left, right), do: :erlang.apply(Descr, :opt_union, [left, right])

  @impl SpecLint.Compiler
  @spec intersection(SpecLint.Compiler.descr(), SpecLint.Compiler.descr()) ::
          SpecLint.Compiler.descr()
  def intersection(left, right), do: :erlang.apply(Descr, :opt_intersection, [left, right])

  @impl SpecLint.Compiler
  @spec difference(SpecLint.Compiler.descr(), SpecLint.Compiler.descr()) ::
          SpecLint.Compiler.descr()
  def difference(left, right), do: :erlang.apply(Descr, :opt_difference, [left, right])

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
  def atom_fetch(descr), do: Descr.atom_fetch(unfold_node(descr))

  # Recursive type nodes ({id, state, generator}) must be expanded before
  # functions that pattern match on the descr map.
  defp unfold_node({_id, _state, _generator} = node), do: unfold(node)
  defp unfold_node(descr), do: descr

  defp unfold(descr), do: :erlang.apply(Descr, :unfold, [descr])

  # Descr.to_domain_keys/1 skips a finite atom component, because the
  # compiler's callers split finite atoms out first. Reporting :atom for it
  # keeps the kinds an upper bound of the key.
  @impl SpecLint.Compiler
  @spec key_kinds(SpecLint.Compiler.descr()) :: [SpecLint.Compiler.key_kind()]
  def key_kinds(descr) do
    atoms? = not Descr.empty?(intersection(descr, Descr.atom()))

    descr
    |> Descr.to_domain_keys()
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

  # Structural, not semantic (DESIGN.md section 9). Recursive nodes, the
  # only VM-specific values of this line's descr terms (inference does not
  # produce them today), are unfolded to a fixed depth and cut off with a
  # marker (SpecLint.Compiler.DescrWalk).
  @impl SpecLint.Compiler
  @spec canonical(SpecLint.Compiler.descr()) :: term()
  def canonical(descr), do: DescrWalk.canonical(__MODULE__, descr)

  ## DescrWalk hooks

  # Descr.unfold/1 expands term() and recursive nodes (audit row 8).
  @impl DescrWalk
  @spec expand(SpecLint.Compiler.descr()) :: map()
  def expand(descr), do: descr |> unfold_node() |> unfold()

  @impl DescrWalk
  @spec recursive_node?(term()) :: boolean()
  def recursive_node?({id, _state, generator})
      when is_reference(id) and is_function(generator, 1),
      do: true

  def recursive_node?(_term), do: false

  # Map literals are {hash, :closed | :open | [{kind, value}], [{key,
  # {value, optional?}}]}; a literal with key domains is closed apart from
  # them.
  @impl DescrWalk
  @spec map_view(tuple()) :: SpecLint.Compiler.view()
  def map_view({_, tag, fields}) do
    fields = for {key, {value, optional?}} <- fields, do: {key, value, optional?}

    case tag do
      tag when tag in [:open, :closed] -> {:map, tag, fields, []}
      domains -> {:map, :closed, fields, for({kind, value} <- domains, do: {[kind], value})}
    end
  end
end
