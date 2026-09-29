defmodule SpecLint.Compiler.V121 do
  @moduledoc """
  Compiler adapter for Elixir 1.21 development builds with checker chunk
  `:elixir_checker_v10`.

  Qualified for the Elixir revisions in `qualified_revisions/0` only:
  `c24c235` (the fork revision SpecLint was developed on) and the upstream
  revision `648b2a9`. `preflight/0` rejects any other build, even one
  writing the same checker chunk version, because `Descr` and
  `apply_infer/2` change between revisions without a chunk version bump.
  The audit behind each revision is in `bench/corpus/toolchain/`.

  Preflight does not trust the revision alone: it runs one capability probe
  per compiler internal SpecLint depends on (`capability_probes/0`), and
  any probe that fails makes preflight fail, so a build whose internals
  changed is reported as unsupported (exit 2 in CI), never analysed with a
  stale copy. `preflight/1` takes the internals to probe, so tests can
  substitute a missing or changed one.

  This is the only module in SpecLint that calls `Module.Types`,
  `Module.Types.Descr`, `Module.ParallelChecker` or `:elixir_erl`.
  `apply_infer/2` is a line-by-line copy of the private
  `Module.Types.Apply.apply_infer/2` of the qualified revisions (identical
  in both), including its clause cutoff; differential tests and the
  `:apply_infer` probe compare it with the compiler's own application
  through `Module.Types.Apply.remote_apply/7`.
  """

  @behaviour SpecLint.Compiler

  alias Module.Types.Descr

  # Mirrors Module.Types.Apply @max_clauses.
  @max_clauses 16
  @checker_version :elixir_checker_v10
  @version_requirement "~> 1.21.0-dev"
  # Elixir revisions (short SHA, `System.build_info()[:revision]`) against
  # which the apply_infer/2 copy, the Descr encodings and every other
  # internal were qualified (bench/corpus/toolchain/audit-648b2a9.md).
  @qualified_revisions ["c24c235", "648b2a9"]

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

  # Bits of the descr bitmap, read by components/1 and probed by preflight/0.
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

  @typedoc """
  The compiler internals `preflight/1` probes, by role: `Module.Types.Descr`,
  `Module.Types.Apply`, `Module.Types`, `Module.Types.Pattern`,
  `Module.ParallelChecker`, `:elixir_erl`, `Code.Typespec`,
  `Mix.Compilers.Elixir`, and a BEAM file whose `ExCk` chunk is decoded as
  a sample (`exck_sample`). `internals/0` gives the running compiler's.
  """
  @type internals :: %{
          descr: module(),
          apply: module(),
          types: module(),
          pattern: module(),
          checker: module(),
          erl: module(),
          typespec: module(),
          manifest: module(),
          exck_sample: String.t()
        }

  @typedoc "A capability probe, one per audited compiler internal."
  @type probe ::
          :descr_exports
          | :descr_encoding
          | :descr_semantics
          | :checker_version
          | :checker_chunk
          | :apply_infer
          | :pattern_checker
          | :typespec_kinds
          | :compile_manifest

  @probes [
    :descr_exports,
    :descr_encoding,
    :descr_semantics,
    :checker_version,
    :checker_chunk,
    :apply_infer,
    :pattern_checker,
    :typespec_kinds,
    :compile_manifest
  ]

  @impl true
  @spec preflight() :: {:ok, SpecLint.Compiler.capabilities()} | {:error, term()}
  def preflight, do: preflight(internals())

  @doc """
  `preflight/0` against `internals`: checks the build revision, that every
  internal module loads, and runs every capability probe in
  `capability_probes/0`. The first failure is returned as
  `{:error, {:capability_probe_failed, probe, detail}}`; a probe that
  raises fails with the exception message.
  """
  @spec preflight(internals()) :: {:ok, SpecLint.Compiler.capabilities()} | {:error, term()}
  def preflight(internals) do
    version = System.version()
    revision = System.build_info()[:revision]

    with :ok <- check_build(version, revision),
         :ok <- check_loaded(internals),
         :ok <- run_probes(internals) do
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
         # check_loaded/1 loaded Module.Types; function_exported?/3 does not.
         body_hook: function_exported?(internals.types, :warnings, 7)
       }}
    end
  end

  @doc "The running compiler's internals, as `preflight/1` probes them."
  @spec internals() :: internals()
  def internals do
    %{
      descr: Module.Types.Descr,
      apply: Module.Types.Apply,
      types: Module.Types,
      pattern: Module.Types.Pattern,
      checker: Module.ParallelChecker,
      erl: :elixir_erl,
      typespec: Code.Typespec,
      manifest: Mix.Compilers.Elixir,
      exck_sample: beam_path(Keyword)
    }
  end

  defp beam_path(module) do
    case :code.which(module) do
      path when is_list(path) -> List.to_string(path)
      _other -> ""
    end
  end

  @doc "The capability probes `preflight/1` runs, in order."
  @spec capability_probes() :: [probe(), ...]
  def capability_probes, do: @probes

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

  defp check_loaded(internals) do
    modules =
      internals
      |> Map.take([:descr, :apply, :types, :pattern, :checker, :erl, :typespec, :manifest])
      |> Map.values()
      |> Enum.sort()

    missing = Enum.reject(modules, &Code.ensure_loaded?/1)

    if missing == [], do: :ok, else: {:error, {:missing_compiler_modules, missing}}
  end

  defp run_probes(internals) do
    Enum.reduce_while(@probes, :ok, fn probe, :ok ->
      case probe(probe, internals) do
        :ok -> {:cont, :ok}
        {:error, detail} -> {:halt, {:error, {:capability_probe_failed, probe, detail}}}
      end
    end)
  end

  @doc """
  Runs one capability probe against `internals`: `:ok`, or `{:error,
  detail}` saying what is missing or changed. Never raises: an exception
  or exit inside the probe is a failure.

    * `:descr_exports` - every `Module.Types.Descr` function the adapter
      calls is exported with the arity it calls.
    * `:descr_encoding` - the term layout the adapter reads directly
      (`components/1`, `closed_map/2`, `canonical/1`): the bitmap bits,
      atom sets, tuple, map and list literals in `bdd_to_dnf/1` lines,
      map fields and key domains, `fun()`, `dynamic`, `term` and `none`.
    * `:descr_semantics` - function contravariance, optional map fields
      and key domains, gradual bounds, `to_domain_keys/1`, `atom_fetch/1`
      and the `to_quoted_string/2` option the printer passes.
    * `:checker_version` - `:elixir_erl.checker_version/0` exists and
      returns the qualified chunk version.
    * `:checker_chunk` - the `ExCk` chunk of `exck_sample` has the shape
      the decoder reads: `{version, %{exports: [{{f, a}, %{sig: sig}}],
      mode: mode}}` with clause signatures of the right arity.
    * `:apply_infer` - this adapter's copy of `apply_infer/2` agrees with
      `Module.Types.Apply.remote_apply/7` (through `Module.Types.stack/7`
      and `context/0`) on fixed clause sets: clause selection, no applicable
      clause, and both sides of the 16-clause cutoff.
    * `:pattern_checker` - `Module.Types.warnings/6` and the checker cache
      exist, `Module.Types.Pattern.of_head/8` and `of_guard/5` exist, and
      a clause whose guard contradicts its pattern is reported (and a live
      one is not).
    * `:typespec_kinds` - `Code.Typespec.fetch_types/1` returns the kinds
      `:type`, `:typep`, `:opaque` and (OTP 28 and later) `:nominal`, in
      the `{kind, {name, ast, args}}` form the translator reads.
    * `:compile_manifest` - `Mix.Compilers.Elixir.read_manifest/1` exists
      and returns the `{[], []}` sentinel for an unreadable manifest.
  """
  @spec probe(probe(), internals()) :: :ok | {:error, term()}
  def probe(probe, internals) when probe in @probes do
    run_probe(probe, internals)
  rescue
    error -> {:error, {:raised, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp run_probe(:descr_exports, %{descr: descr}) do
    missing = Enum.reject(@required_descr, fn {f, a} -> function_exported?(descr, f, a) end)
    if missing == [], do: :ok, else: {:error, {:missing_descr_functions, missing}}
  end

  defp run_probe(:descr_encoding, %{descr: descr}), do: failed_checks(encoding_checks(descr))
  defp run_probe(:descr_semantics, %{descr: descr}), do: failed_checks(semantic_checks(descr))

  defp run_probe(:checker_version, %{erl: erl}) do
    if function_exported?(erl, :checker_version, 0) do
      case :erlang.apply(erl, :checker_version, []) do
        @checker_version -> :ok
        other -> {:error, {:unsupported_checker_version, other, @checker_version}}
      end
    else
      {:error, :no_checker_version}
    end
  end

  defp run_probe(:checker_chunk, %{exck_sample: path}) do
    case :beam_lib.chunks(String.to_charlist(path), [~c"ExCk"]) do
      {:ok, {_module, [{~c"ExCk", bytes}]}} -> check_chunk_shape(bytes)
      {:error, :beam_lib, reason} -> {:error, {:no_sample_chunk, reason}}
    end
  end

  defp run_probe(:apply_infer, %{apply: apply, types: types} = internals) do
    required = [{apply, :remote_apply, 7}, {types, :stack, 7}, {types, :context, 0}]

    case Enum.reject(required, fn {m, f, a} -> function_exported?(m, f, a) end) do
      [] -> failed_checks(apply_checks(internals))
      missing -> {:error, {:missing_functions, missing}}
    end
  end

  defp run_probe(:pattern_checker, internals) do
    required = [
      {internals.types, :warnings, 6},
      {internals.checker, :start_link, 1},
      {internals.checker, :stop, 1},
      {internals.pattern, :of_head, 8},
      {internals.pattern, :of_guard, 5}
    ]

    case Enum.reject(required, fn {m, f, a} -> function_exported?(m, f, a) end) do
      [] -> check_pattern_diagnostics(internals)
      missing -> {:error, {:missing_functions, missing}}
    end
  end

  defp run_probe(:typespec_kinds, %{typespec: typespec}) do
    if function_exported?(typespec, :fetch_types, 1),
      do: check_typespec_kinds(typespec),
      else: {:error, {:missing_functions, [{typespec, :fetch_types, 1}]}}
  end

  defp run_probe(:compile_manifest, %{manifest: manifest}) do
    cond do
      not function_exported?(manifest, :read_manifest, 1) ->
        {:error, {:missing_functions, [{manifest, :read_manifest, 1}]}}

      # /dev/null is a file, so nothing can exist below it.
      (result = manifest.read_manifest("/dev/null/spec_lint/compile.elixir")) != {[], []} ->
        {:error, {:unreadable_manifest_result, result}}

      true ->
        :ok
    end
  end

  defp failed_checks(checks) do
    case for({name, false} <- checks, do: name) do
      [] -> :ok
      failed -> {:error, {:checks_failed, failed}}
    end
  end

  # The layout components/1, closed_map/2 and canonical/1 read.
  defp encoding_checks(d) do
    int = d.integer()
    ok = d.atom([:ok])
    atom_top = d.atom()

    [
      bitmap:
        Enum.all?(@bit_kinds, fn {kind, bit} -> apply(d, kind, []) == %{bitmap: bit} end) and
          d.empty_list() == %{bitmap: @bit_empty_list},
      atom_union: match?(%{atom: {:union, _}}, ok) and atom_set(ok) == [:ok],
      atom_negation:
        match?(%{atom: {:negation, _}}, d.opt_difference(atom_top, ok)) and
          atom_set(d.opt_difference(atom_top, ok)) == [:ok],
      closed_tuple: tuple_line(d, d.tuple([ok]), :closed, ok),
      open_tuple: tuple_line(d, d.open_tuple([ok]), :open, ok),
      closed_map: map_line(d, d.closed_map([{:a, {int, true}}, {[:binary], atom_top}]), int),
      open_map: match?([{[{_, :open, []}], []}], d.bdd_to_dnf(d.open_map().map)),
      list: list_line(d, d.non_empty_list(int, d.empty_list()), int),
      fun: whole_fun?(d.fun()),
      dynamic: d.dynamic(int) == %{dynamic: int},
      term: d.term() == :term,
      none: d.none() == %{},
      unfold: d.unfold(int) == int
    ]
  end

  defp atom_set(%{atom: {_tag, set}}), do: set |> :sets.to_list() |> Enum.sort()

  defp tuple_line(d, %{tuple: bdd}, tag, element) do
    case d.bdd_to_dnf(bdd) do
      [{[{_hash, ^tag, [stored]}], []}] -> d.equal?(stored, element)
      _other -> false
    end
  end

  defp tuple_line(_d, _descr, _tag, _element), do: false

  defp map_line(d, %{map: bdd}, int) do
    case d.bdd_to_dnf(bdd) do
      [{[{_hash, [binary: domain], [a: {value, true}]}], []}] ->
        d.equal?(domain, d.atom()) and d.equal?(value, int)

      _other ->
        false
    end
  end

  defp map_line(_d, _descr, _int), do: false

  defp list_line(d, %{list: bdd}, int) do
    case d.bdd_to_dnf(bdd) do
      [{[{_hash, element, tail}], []}] ->
        d.equal?(element, int) and d.equal?(tail, d.empty_list())

      _other ->
        false
    end
  end

  defp list_line(_d, _descr, _int), do: false

  defp whole_fun?(%{fun: {:negation, bdds}}) when map_size(bdds) == 0, do: true
  defp whole_fun?(_descr), do: false

  defp semantic_checks(d) do
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
      atom_fetch: finite_atoms(d.atom_fetch(d.atom([:b, :a]))) == [:a, :b],
      quoted_dynamic:
        d.to_quoted_string(dyn_int, skip_dynamic_for_indivisible: false) == "dynamic(integer())"
    ]
  end

  defp finite_atoms({:finite, atoms}) when is_list(atoms), do: Enum.sort(atoms)
  defp finite_atoms(_other), do: :not_finite

  defp check_chunk_shape(bytes) do
    case decode_term(bytes) do
      {:ok, {@checker_version, %{exports: exports, mode: mode}}}
      when is_list(exports) and is_atom(mode) ->
        check_exports_shape(exports, bytes)

      {:ok, {version, _contents}} when version != @checker_version ->
        {:error, {:checker_version_mismatch, version, @checker_version}}

      _other ->
        {:error, :malformed_sample_chunk}
    end
  end

  defp check_exports_shape(exports, bytes) do
    signed =
      for {{_f, a}, %{sig: {kind, _domain, clauses}}} <- exports,
          kind in [:infer, :strong],
          do: {a, clauses}

    cond do
      not Enum.all?(exports, &match?({{f, a}, %{}} when is_atom(f) and is_integer(a), &1)) ->
        {:error, :export_shape_changed}

      signed == [] ->
        {:error, :no_stored_signatures}

      not Enum.all?(signed, fn {arity, clauses} ->
        Enum.all?(clauses, &clause_shape?(&1, arity))
      end) ->
        {:error, :clause_shape_changed}

      not decodes_signatures?(bytes, length(signed)) ->
        {:error, :decoder_disagrees}

      true ->
        :ok
    end
  end

  defp clause_shape?({args, return}, arity) when is_list(args) and length(args) == arity,
    do: Enum.all?([return | args], &descr_term?/1)

  defp clause_shape?(_clause, _arity), do: false

  defp descr_term?(descr), do: descr == :term or is_map(descr)

  defp decodes_signatures?(bytes, count) do
    case decode_qualified(bytes, @checker_version) do
      {:ok, chunk} -> Enum.count(chunk.exports, fn {_, %{sig: sig}} -> sig != :none end) == count
      {:error, _reason} -> false
    end
  end

  defp apply_checks(internals) do
    int = Descr.integer()
    atom_a = Descr.atom([:a])
    atom_b = Descr.atom([:b])

    selection = [
      {[int, Descr.atom()], atom_a},
      {[Descr.atom(), Descr.atom()], atom_b},
      {[Descr.opt_union(int, Descr.float()), Descr.term()], Descr.atom([:c])}
    ]

    at_cutoff = for i <- 1..@max_clauses, do: {[Descr.term()], Descr.atom([:"a#{i}"])}
    over_cutoff = [{[Descr.term()], atom_b} | at_cutoff]

    [
      selection: agrees?(internals, selection, [int, Descr.atom([:x])]),
      gradual_argument: agrees?(internals, selection, [Descr.dynamic(), Descr.dynamic()]),
      no_clause: agrees?(internals, selection, [Descr.binary(), Descr.atom()]),
      at_cutoff:
        agrees?(internals, at_cutoff, [int]) and
          elem(apply_infer(at_cutoff, [int]), 1) != Descr.dynamic(),
      over_cutoff:
        agrees?(internals, over_cutoff, [int]) and
          elem(apply_infer(over_cutoff, [int]), 1) == Descr.dynamic()
    ]
  end

  defp agrees?(internals, clauses, args) do
    case {apply_infer(clauses, args), compiler_apply(internals, clauses, args)} do
      {:error, :error} -> true
      {{_used, type}, {:ok, type}} -> true
      _disagree -> false
    end
  end

  defp compiler_apply(%{apply: apply, types: types}, clauses, args) do
    module = SpecLintProbe
    handler = fn _, _, _, _ -> false end
    stack = types.stack(:dynamic, "nofile", module, {:f, length(args)}, :all, nil, handler)
    expr = {{:., [], [module, :f]}, [line: 1], []}

    case apply.remote_apply(
           {:infer, nil, clauses},
           module,
           :f,
           args,
           expr,
           stack,
           types.context()
         ) do
      {_type, %{failed: true}} -> :error
      {type, %{failed: false}} -> {:ok, type}
    end
  end

  # Debug info definitions (the compiler's expanded form) of
  #
  #     def g(:b = x) when is_integer(x), do: x   # line 2: dead clause
  #     def g(y), do: y
  #     def h(x) when is_atom(x), do: x           # line 4: live
  #
  @probe_definitions [
    {{:g, 1}, :def, [line: 2],
     [
       {[line: 2], [{:=, [line: 2], [:b, {:x, [version: 0, line: 2], nil}]}],
        [
          {{:., [line: 2], [:erlang, :is_integer]}, [line: 2], [{:x, [version: 0, line: 2], nil}]}
        ], {:x, [version: 0, line: 2], nil}},
       {[line: 3], [{:y, [version: 0, line: 3], nil}], [], {:y, [version: 0, line: 3], nil}}
     ]},
    {{:h, 1}, :def, [line: 4],
     [
       {[line: 4], [{:x, [version: 0, line: 4], nil}],
        [{{:., [line: 4], [:erlang, :is_atom]}, [line: 4], [{:x, [version: 0, line: 4], nil}]}],
        {:x, [version: 0, line: 4], nil}}
     ]}
  ]

  defp check_pattern_diagnostics(internals) do
    case run_checker(internals, SpecLintProbe, "nofile", [], @probe_definitions) do
      {:ok, [{{:g, 1}, 2}]} -> :ok
      {:ok, other} -> {:error, {:unexpected_diagnostics, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  # An Erlang module with one type of each kind, compiled in memory (never
  # loaded); fetch_types/1 reads its debug info. `:nominal` exists from
  # OTP 28 on.
  defp check_typespec_kinds(typespec) do
    nominal? = String.to_integer(System.otp_release()) >= 28
    expected = if nominal?, do: [:nominal, :opaque, :type, :typep], else: [:opaque, :type, :typep]

    case typespec.fetch_types(typespec_probe_binary(nominal?)) do
      {:ok, fetched} -> check_fetched_types(fetched, expected)
      other -> {:error, {:fetch_types_failed, other}}
    end
  end

  defp typespec_probe_binary(nominal?) do
    types =
      [t: {:type, :integer}, o: {:opaque, :atom}, p: {:type, :float}] ++
        if(nominal?, do: [n: {:nominal, :binary}], else: [])

    exported = for {name, _} <- types, name != :p, do: {name, 0}

    forms =
      [
        {:attribute, 1, :module, :spec_lint_typespec_probe},
        {:attribute, 1, :export_type, exported}
        | for(
            {name, {kind, builtin}} <- types,
            do: {:attribute, 1, kind, {name, {:type, 1, builtin, []}, []}}
          )
      ]

    {:ok, _module, binary} = :compile.forms(forms, [:binary, :debug_info, :return_errors])
    binary
  end

  defp check_fetched_types(fetched, expected) do
    kinds = fetched |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    cond do
      kinds != expected -> {:error, {:type_kinds_changed, kinds}}
      {:type, {:t, {:type, 1, :integer, []}, []}} not in fetched -> {:error, :type_shape_changed}
      true -> :ok
    end
  end

  # The checker version is a property of the running compiler, not of the
  # Elixir build SpecLint was analysed against, so it is read dynamically.
  # An apply keeps Dialyzer from specialising the result on the checker
  # version of the Elixir this was built with. `:erlang.apply/3` rather than
  # `Kernel.apply/3`: the arguments are known but the value must stay open.
  defp running_checker_version, do: :erlang.apply(:elixir_erl, :checker_version, [])

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

  # Re-runs Module.Types.warnings/6, what Module.ParallelChecker runs over
  # every module after compilation, with a private checker cache for remote
  # lookups (read from object code on the code path, never loaded). Only the
  # warnings Module.Types.Pattern emits are kept (clause heads and guards,
  # including patterns and guards inside the body), plus unused private
  # clauses. The checker may load a struct module that a pattern names to
  # read its fields, as compilation already did to expand the struct.
  @impl true
  @spec pattern_diagnostics(module(), String.t() | nil, keyword(), [tuple()]) ::
          {:ok, [SpecLint.Compiler.pattern_diagnostic()]} | {:error, term()}
  def pattern_diagnostics(module, file, attributes, definitions) do
    internals = internals()

    if function_exported?(internals.types, :warnings, 6) and
         function_exported?(internals.checker, :start_link, 1) do
      run_checker(internals, module, file, attributes, definitions)
    else
      {:error, :checker_unavailable}
    end
  end

  defp run_checker(%{types: types, checker: checker}, module, file, attributes, definitions) do
    {:ok, cache} = checker.start_link([])

    try do
      warnings = types.warnings(module, file || "nofile", attributes, definitions, [], cache)
      {:ok, warnings |> Enum.flat_map(&pattern_diagnostic/1) |> Enum.uniq() |> Enum.sort()}
    rescue
      error -> {:error, {:checker_failed, Exception.message(error)}}
    catch
      kind, reason -> {:error, {:checker_failed, {kind, reason}}}
    after
      :ok = checker.stop(cache)
    end
  end

  defp pattern_diagnostic({Module.Types.Pattern, _warning, {_file, meta, {_mod, fun, arity}}}),
    do: [{{fun, arity}, line(meta)}]

  defp pattern_diagnostic(
         {Module.Types, {:unused_clause, _kind, _fun_arity}, {_file, meta, {_mod, fun, arity}}}
       ),
       do: [{{fun, arity}, line(meta)}]

  defp pattern_diagnostic(_warning), do: []

  defp line(meta) do
    case Keyword.get(meta, :line) do
      line when is_integer(line) and line > 0 -> line
      _ -> nil
    end
  end

  # Copy of Module.Types.Apply.apply_infer/2 (Elixir c24c235, unchanged in
  # 648b2a9). Keep the
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
      {:ok, direct, memo} = normal_form_string(descr, :infinity, %{})
      direct_length = String.length(direct)

      complement
      |> normal_form_string(direct_length - String.length("not "), memo)
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
  defp normal_form_string(descr, budget, memo) do
    static = descr |> unfold_node() |> Descr.unfold()
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
         {:ok, acc} <- add_lines(lines, acc, budget) do
      string =
        case Enum.reverse(acc.pieces) do
          [single] -> single
          pieces -> Enum.map_join(pieces, " or ", &parenthesise_and/1)
        end

      {:ok, string, acc.memo}
    end
  end

  defp add_lines([], acc, _budget), do: {:ok, acc}

  defp add_lines([{kind, dnf_line} | lines], acc, budget) do
    {printed, memo} = line(kind, dnf_line, acc.memo)
    acc = %{acc | memo: memo}

    acc = Enum.reduce(printed, acc, &add_piece/2)
    with {:ok, acc} <- within_budget(acc, budget), do: add_lines(lines, acc, budget)
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

  defp line(kind, {pos, negs}, memo) do
    positives = if pos == [], do: [top_literal(kind)], else: pos
    pos_descr = positives |> Enum.map(&%{kind => &1}) |> Enum.reduce(&Descr.opt_intersection/2)
    live = Enum.reject(negs, &Descr.disjoint?(pos_descr, %{kind => &1}))
    line = Enum.reduce(live, pos_descr, &Descr.opt_difference(&2, %{kind => &1}))

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
