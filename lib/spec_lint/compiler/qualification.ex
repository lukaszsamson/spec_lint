defmodule SpecLint.Compiler.Qualification do
  @moduledoc """
  Preflight and capability probes shared by the compiler adapters
  (`SpecLint.Compiler.V121`, `SpecLint.Compiler.V120`).

  An adapter is qualified for a list of Elixir revisions. Its preflight
  checks the running build against that list, then compares the code of the
  pinned compiler modules with the digests recorded per revision
  (`:compiler_identity`, `SpecLint.Compiler.BuildIdentity`), then runs one
  capability probe per compiler internal SpecLint depends on
  (`probes/0`). Any failure makes preflight fail, so a build whose
  internals changed is reported as unsupported (exit 2 in CI), never
  analysed with a stale copy.

  The probes that are the same on every qualified compiler live here: the
  build identity, the checker chunk version and layout, the debug info
  contract, the `apply_infer/2` copy against `remote_apply/7`, the pattern
  and guard checker, the `Code.Typespec` kinds and the compile manifest
  reader. The three `Module.Types.Descr` probes (`:descr_exports`,
  `:descr_encoding`, `:descr_semantics`) read what differs between compiler
  lines, so each adapter supplies them through the callbacks of this
  behaviour (the export list, and the encoding and semantic checks with
  their expected values). The `apply_infer/2` probe runs the adapter's own
  copy.

  Besides the adapters, this is the module that calls `Module.Types`,
  `Module.Types.Apply`, `Module.ParallelChecker`, `:elixir_erl`,
  `Code.Typespec` and `Mix.Compilers.Elixir` by name (through `internals/0`,
  so tests can substitute a changed internal).
  """

  alias SpecLint.Compiler.BuildIdentity

  @typedoc """
  The compiler internals `preflight/2` probes, by role: `Module.Types.Descr`,
  `Module.Types.Apply`, `Module.Types`, `Module.Types.Pattern`,
  `Module.ParallelChecker`, `:elixir_erl`, `Code.Typespec`,
  `Mix.Compilers.Elixir`, a BEAM file whose `ExCk` chunk is decoded as
  a sample (`exck_sample`), and the ebin directories holding the pinned
  compiler modules (`build_ebins`). `internals/0` gives the running
  compiler's.
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
          exck_sample: String.t(),
          build_ebins: [String.t()]
        }

  @typedoc "A capability probe, one per audited compiler internal."
  @type probe ::
          :compiler_identity
          | :descr_exports
          | :descr_encoding
          | :descr_semantics
          | :checker_version
          | :checker_chunk
          | :debug_info
          | :apply_infer
          | :pattern_checker
          | :typespec_kinds
          | :compile_manifest

  @typedoc "What a failed probe reports: a reason atom or a tagged tuple."
  @type probe_error :: atom() | tuple()

  @typedoc "Named boolean checks of one probe; the failing names are reported."
  @type checks :: [{atom(), boolean()}]

  @doc "The Elixir revisions (short commit SHAs) the adapter is qualified for."
  @callback qualified_revisions() :: [String.t(), ...]

  @doc "Per qualified revision, the code digests of the pinned compiler modules."
  @callback qualified_builds() :: %{String.t() => BuildIdentity.digests()}

  @doc "The `Version` requirement the running Elixir must match."
  @callback version_requirement() :: String.t()

  @doc "The `Module.Types.Descr` functions the adapter calls, as `{name, arity}`."
  @callback required_descr() :: [{atom(), 0 | 1 | 2}, ...]

  @doc "The `:descr_encoding` checks against a `Module.Types.Descr` module."
  @callback encoding_checks(module()) :: checks()

  @doc "The `:descr_semantics` checks against a `Module.Types.Descr` module."
  @callback semantic_checks(module()) :: checks()

  @doc """
  Whether the compiler line has recursive type nodes (`Descr.recursive/1`
  and `Descr.unfold/1`). SpecLint builds none either way: recursive
  typespecs are cut off by `SpecLint.Translate` with `:recursive_cutoff`.
  """
  @callback recursive_types?() :: boolean()

  @doc """
  Whether `Code.Typespec.fetch_types/1` reports Erlang `-nominal` types
  (OTP 28 and later) as `:nominal`. When it does not, it leaves them out,
  and a remote reference to one translates as `:unresolved_remote_type`
  (the same bounds as `:nominal_boundary`: `term()` above, `none()` below).
  """
  @callback nominal_types?() :: boolean()

  @probes [
    :compiler_identity,
    :descr_exports,
    :descr_encoding,
    :descr_semantics,
    :checker_version,
    :checker_chunk,
    :debug_info,
    :apply_infer,
    :pattern_checker,
    :typespec_kinds,
    :compile_manifest
  ]

  @doc "The capability probes `preflight/2` runs, in order."
  @spec probes() :: [probe(), ...]
  def probes, do: @probes

  @doc """
  Preflight of `adapter` against `internals`: checks the build revision,
  that every internal module loads, and runs every capability probe in
  `probes/0`. The first failure is returned as `{:error,
  {:capability_probe_failed, probe, detail}}`; a probe that raises fails
  with the exception message.
  """
  @spec preflight(module(), internals()) ::
          {:ok, SpecLint.Compiler.capabilities()} | {:error, term()}
  def preflight(adapter, internals) do
    version = System.version()
    revision = System.build_info()[:revision]

    with :ok <- check_build(adapter, version, revision),
         :ok <- check_loaded(internals),
         :ok <- run_probes(adapter, internals),
         {:ok, digests} <- build_digests(internals) do
      {:ok,
       %{
         adapter: adapter,
         adapter_id: "#{version}+#{revision}",
         elixir_version: version,
         revision: revision,
         build_digest: BuildIdentity.combined(digests),
         otp_release: System.otp_release(),
         checker_version: adapter.qualified_checker_version(),
         max_clauses: adapter.max_clauses(),
         signatures: true,
         recursive_types: adapter.recursive_types?(),
         # check_loaded/1 loaded Module.Types; function_exported?/3 does not.
         body_hook: function_exported?(internals.types, :warnings, 7)
       }}
    end
  end

  @doc "The running compiler's internals, as `preflight/2` probes them."
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
      exck_sample: beam_path(Keyword),
      build_ebins: BuildIdentity.running_ebins()
    }
  end

  defp build_digests(%{build_ebins: ebins}) do
    result =
      if ebins == BuildIdentity.running_ebins(),
        do: BuildIdentity.running_digests(),
        else: BuildIdentity.digests(ebins)

    case result do
      {:ok, digests} -> {:ok, digests}
      {:error, reason} -> {:error, {:capability_probe_failed, :compiler_identity, reason}}
    end
  end

  defp beam_path(module) do
    case :code.which(module) do
      path when is_list(path) -> List.to_string(path)
      _other -> ""
    end
  end

  @doc """
  Checks an Elixir version and build revision against `adapter`'s
  qualification (`version_requirement/0`, `qualified_revisions/0`).
  """
  @spec check_build(module(), String.t(), String.t() | nil) ::
          :ok
          | {:error, {:unsupported_elixir, String.t(), String.t()}}
          | {:error, {:unqualified_revision, String.t() | nil, [String.t()]}}
  def check_build(adapter, version, revision) do
    with :ok <- check_version(version, adapter.version_requirement()) do
      check_revision(revision, adapter.qualified_revisions())
    end
  end

  @doc "Whether `version` matches the `Version` requirement (pre-releases included)."
  @spec version_matches?(String.t(), String.t()) :: boolean()
  def version_matches?(version, requirement) do
    case Version.parse(version) do
      {:ok, parsed} -> Version.match?(parsed, requirement, allow_pre: true)
      :error -> false
    end
  end

  defp check_version(version, requirement) do
    if version_matches?(version, requirement),
      do: :ok,
      else: {:error, {:unsupported_elixir, version, requirement}}
  end

  defp check_revision(revision, qualified)
       when is_binary(revision) and byte_size(revision) >= 7 do
    if String.slice(revision, 0, 7) in qualified,
      do: :ok,
      else: {:error, {:unqualified_revision, revision, qualified}}
  end

  defp check_revision(revision, qualified),
    do: {:error, {:unqualified_revision, revision, qualified}}

  defp check_loaded(internals) do
    modules =
      internals
      |> Map.take([:descr, :apply, :types, :pattern, :checker, :erl, :typespec, :manifest])
      |> Map.values()
      |> Enum.sort()

    missing = Enum.reject(modules, &Code.ensure_loaded?/1)

    if missing == [], do: :ok, else: {:error, {:missing_compiler_modules, missing}}
  end

  defp run_probes(adapter, internals) do
    Enum.reduce_while(@probes, :ok, fn probe, :ok ->
      case probe(adapter, probe, internals) do
        :ok -> {:cont, :ok}
        {:error, detail} -> {:halt, {:error, {:capability_probe_failed, probe, detail}}}
      end
    end)
  end

  @doc """
  Runs one capability probe of `adapter` against `internals`: `:ok`, or
  `{:error, detail}` saying what is missing or changed. Never raises: an
  exception or exit inside the probe is a failure.

    * `:compiler_identity` - the pinned compiler modules in `build_ebins`
      have the code digests recorded for the running revision
      (`qualified_builds/0`); the detail names every module that differs,
      is missing or is extra.
    * `:descr_exports` - every `Module.Types.Descr` function the adapter
      calls (`required_descr/0`) is exported with the arity it calls.
    * `:descr_encoding` - the term layout the adapter reads directly
      (`encoding_checks/1`).
    * `:descr_semantics` - the `Descr` semantics the adapter relies on
      (`semantic_checks/1`).
    * `:checker_version` - `:elixir_erl.checker_version/0` exists and
      returns the adapter's chunk version.
    * `:checker_chunk` - the `ExCk` chunk of `exck_sample` has the shape
      the decoder reads: `{version, %{exports: [{{f, a}, %{sig: sig}}],
      mode: mode}}` with clause signatures of the right arity.
    * `:debug_info` - a small `use GenServer` module, compiled in memory
      and unloaded again, has a `:debug_info_v1` chunk with the
      `:elixir_erl` backend, and `debug_info(:elixir_v1, ...)` of the
      `erl` internal returns what `SpecLint.Beam` reads: `definitions` as
      `{{name, arity}, kind, meta, clauses}` with four-element clauses, a
      binary `file`, an `attributes` list, the `:line` of a definition,
      `generated: true` on a definition whose name was generated, and
      `from_super: false` on an overridable default that was not
      overridden (and no `:from_super` on one that was).
    * `:apply_infer` - the adapter's copy of `apply_infer/2` agrees with
      `Module.Types.Apply.remote_apply/7` (through `Module.Types.stack/7`
      and `context/0`) on fixed clause sets: clause selection, no applicable
      clause, and both sides of the clause cutoff.
    * `:pattern_checker` - `Module.Types.warnings/6` and the checker cache
      exist, `Module.Types.Pattern.of_head/8` and `of_guard/5` exist, a
      clause whose guard contradicts its pattern is reported (and a live
      one is not), and so is a private clause no caller can reach (the
      `{Module.Types, {:unused_clause, kind, fun_arity}, location}`
      diagnostic).
    * `:typespec_kinds` - `Code.Typespec.fetch_types/1` returns the kinds
      `:type`, `:typep`, `:opaque` and, on OTP 28 and later, `:nominal`
      (or, when the adapter's `nominal_types?/0` is `false`, leaves the
      nominal type out), in the `{kind, {name, ast, args}}` form the
      translator reads;
      `fetch_specs/1` returns `{:ok, [{{name, arity}, [spec]}]}` and
      `spec_to_quoted/2` turns such a spec into a `::` expression.
    * `:compile_manifest` - `Mix.Compilers.Elixir.read_manifest/1` exists
      and returns the `{[], []}` sentinel for an unreadable manifest.
  """
  @spec probe(module(), probe(), internals()) :: :ok | {:error, probe_error()}
  def probe(adapter, probe, internals) when probe in @probes do
    # function_exported?/3 does not load modules.
    for {_role, module} <- internals, is_atom(module), do: _ = Code.ensure_loaded(module)
    run_probe(adapter, probe, internals)
  rescue
    error -> {:error, {:raised, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp run_probe(adapter, :compiler_identity, %{build_ebins: ebins}) do
    revision = String.slice(System.build_info()[:revision] || "", 0, 7)

    with {:ok, recorded} <- Map.fetch(adapter.qualified_builds(), revision),
         {:ok, found} <- BuildIdentity.digests(ebins) do
      case BuildIdentity.differing(recorded, found) do
        [] -> :ok
        modules -> {:error, {:build_differs, revision, modules}}
      end
    else
      :error -> {:error, {:no_recorded_build, revision}}
      {:error, reason} -> {:error, {:unreadable_build, reason}}
    end
  end

  defp run_probe(adapter, :descr_exports, %{descr: descr}) do
    missing =
      Enum.reject(adapter.required_descr(), fn {f, a} -> function_exported?(descr, f, a) end)

    if missing == [], do: :ok, else: {:error, {:missing_descr_functions, missing}}
  end

  defp run_probe(adapter, :descr_encoding, %{descr: descr}),
    do: failed_checks(adapter.encoding_checks(descr))

  defp run_probe(adapter, :descr_semantics, %{descr: descr}),
    do: failed_checks(adapter.semantic_checks(descr))

  defp run_probe(adapter, :checker_version, %{erl: erl}) do
    expected = adapter.qualified_checker_version()

    if function_exported?(erl, :checker_version, 0) do
      case :erlang.apply(erl, :checker_version, []) do
        ^expected -> :ok
        other -> {:error, {:unsupported_checker_version, other, expected}}
      end
    else
      {:error, :no_checker_version}
    end
  end

  defp run_probe(adapter, :checker_chunk, %{exck_sample: path}) do
    case SpecLint.Beam.chunks(path, [~c"ExCk"]) do
      {:ok, {_module, [{~c"ExCk", bytes}]}} ->
        check_chunk_shape(bytes, adapter.qualified_checker_version())

      {:error, :beam_lib, reason} ->
        {:error, {:no_sample_chunk, reason}}
    end
  end

  defp run_probe(_adapter, :debug_info, %{erl: erl}) do
    if function_exported?(erl, :debug_info, 4),
      do: check_debug_info(erl),
      else: {:error, {:missing_functions, [{erl, :debug_info, 4}]}}
  end

  defp run_probe(adapter, :apply_infer, %{apply: apply, types: types} = internals) do
    required = [{apply, :remote_apply, 7}, {types, :stack, 7}, {types, :context, 0}]

    case Enum.reject(required, fn {m, f, a} -> function_exported?(m, f, a) end) do
      [] -> failed_checks(apply_checks(adapter, internals))
      missing -> {:error, {:missing_functions, missing}}
    end
  end

  defp run_probe(_adapter, :pattern_checker, internals) do
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

  defp run_probe(adapter, :typespec_kinds, %{typespec: typespec}) do
    required = [
      {typespec, :fetch_types, 1},
      {typespec, :fetch_specs, 1},
      {typespec, :spec_to_quoted, 2}
    ]

    case Enum.reject(required, fn {m, f, a} -> function_exported?(m, f, a) end) do
      [] -> check_typespecs(adapter, typespec)
      missing -> {:error, {:missing_functions, missing}}
    end
  end

  defp run_probe(_adapter, :compile_manifest, %{manifest: manifest}) do
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

  ## Helpers for the adapters' Descr checks

  @doc "The sorted atoms of an atom set component `%{atom: {tag, set}}`."
  @spec atom_set(map()) :: [atom()]
  def atom_set(%{atom: {_tag, set}}), do: set |> :sets.to_list() |> Enum.sort()

  @doc """
  Whether the tuple part of `descr` is one line holding one literal
  `{hash, tag, [element]}` whose element equals `element`.
  """
  @spec tuple_line?(module(), term(), :closed | :open, term()) :: boolean()
  def tuple_line?(d, %{tuple: bdd}, tag, element) do
    case d.bdd_to_dnf(bdd) do
      [{[{_hash, ^tag, [stored]}], []}] -> d.equal?(stored, element)
      _other -> false
    end
  end

  def tuple_line?(_d, _descr, _tag, _element), do: false

  @doc """
  Whether the non-empty list part of `descr` is one line holding one
  literal `{hash, element, tail}` with `element` and `tail` equal to the
  given ones.
  """
  @spec list_line?(module(), term(), term(), term()) :: boolean()
  def list_line?(d, %{list: bdd}, element, tail) do
    case d.bdd_to_dnf(bdd) do
      [{[{_hash, stored, stored_tail}], []}] ->
        d.equal?(stored, element) and d.equal?(stored_tail, tail)

      _other ->
        false
    end
  end

  def list_line?(_d, _descr, _element, _tail), do: false

  @doc "Whether `descr` is the whole function kind, `%{fun: {:negation, %{}}}`."
  @spec whole_fun?(term()) :: boolean()
  def whole_fun?(%{fun: {:negation, bdds}}) when map_size(bdds) == 0, do: true
  def whole_fun?(_descr), do: false

  @doc "The sorted atoms of `{:finite, atoms}`, or `:not_finite`."
  @spec finite_atoms(term()) :: [atom()] | :not_finite
  def finite_atoms({:finite, atoms}) when is_list(atoms), do: Enum.sort(atoms)
  def finite_atoms(_other), do: :not_finite

  ## Checker chunk

  defp check_chunk_shape(bytes, expected) do
    case decode_term(bytes) do
      {:ok, {^expected, %{exports: exports, mode: mode}}}
      when is_list(exports) and is_atom(mode) ->
        check_exports_shape(exports, bytes, expected)

      {:ok, {version, _contents}} when version != expected ->
        {:error, {:checker_version_mismatch, version, expected}}

      _other ->
        {:error, :malformed_sample_chunk}
    end
  end

  defp check_exports_shape(exports, bytes, expected) do
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

      not decodes_signatures?(bytes, length(signed), expected) ->
        {:error, :decoder_disagrees}

      true ->
        :ok
    end
  end

  defp clause_shape?({args, return}, arity) when is_list(args) and length(args) == arity,
    do: Enum.all?([return | args], &descr_term?/1)

  defp clause_shape?(_clause, _arity), do: false

  defp descr_term?(descr), do: descr == :term or is_map(descr)

  defp decodes_signatures?(bytes, count, expected) do
    case decode_qualified(bytes, expected) do
      {:ok, chunk} -> Enum.count(chunk.exports, fn {_, %{sig: sig}} -> sig != :none end) == count
      {:error, _reason} -> false
    end
  end

  ## apply_infer/2

  defp apply_checks(adapter, internals) do
    int = adapter.integer()
    atom_a = adapter.atom([:a])
    atom_b = adapter.atom([:b])
    max = adapter.max_clauses()

    selection = [
      {[int, adapter.atom()], atom_a},
      {[adapter.atom(), adapter.atom()], atom_b},
      {[adapter.union(int, adapter.float()), adapter.term()], adapter.atom([:c])}
    ]

    at_cutoff = for i <- 1..max, do: {[adapter.term()], adapter.atom([:"a#{i}"])}
    over_cutoff = [{[adapter.term()], atom_b} | at_cutoff]
    dynamic = adapter.dynamic()

    [
      selection: agrees?(adapter, internals, selection, [int, adapter.atom([:x])]),
      gradual_argument: agrees?(adapter, internals, selection, [dynamic, dynamic]),
      no_clause: agrees?(adapter, internals, selection, [adapter.binary(), adapter.atom()]),
      at_cutoff:
        agrees?(adapter, internals, at_cutoff, [int]) and
          elem(adapter.apply_infer(at_cutoff, [int]), 1) != dynamic,
      over_cutoff:
        agrees?(adapter, internals, over_cutoff, [int]) and
          elem(adapter.apply_infer(over_cutoff, [int]), 1) == dynamic
    ]
  end

  defp agrees?(adapter, internals, clauses, args) do
    case {adapter.apply_infer(clauses, args), compiler_apply(internals, clauses, args)} do
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

  ## Pattern and guard checker

  # Debug info definitions (the compiler's expanded form) of
  #
  #     def g(:b = x) when is_integer(x), do: x   # line 2: dead clause
  #     def g(y), do: y
  #     def h(x) when is_atom(x), do: x           # line 4: live
  #     def k, do: priv(1)
  #     defp priv(x) when is_integer(x), do: x
  #     defp priv(:never), do: :never             # line 7: unused clause
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
     ]},
    {{:k, 0}, :def, [line: 5], [{[line: 5], [], [], {:priv, [line: 5], [1]}}]},
    {{:priv, 1}, :defp, [line: 6],
     [
       {[line: 6], [{:x, [version: 0, line: 6], nil}],
        [
          {{:., [line: 6], [:erlang, :is_integer]}, [line: 6], [{:x, [version: 0, line: 6], nil}]}
        ], {:x, [version: 0, line: 6], nil}},
       {[line: 7], [:never], [], :never}
     ]}
  ]

  defp check_pattern_diagnostics(internals) do
    case run_checker(internals, SpecLintProbe, "nofile", [], @probe_definitions) do
      {:ok, [{{:g, 1}, 2}, {{:priv, 1}, 7}]} -> :ok
      {:ok, other} -> {:error, {:unexpected_diagnostics, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Re-runs `Module.Types.warnings/6`, what `Module.ParallelChecker` runs over
  every module after compilation, with a private checker cache for remote
  lookups (read from object code on the code path, never loaded). Only the
  warnings `Module.Types.Pattern` emits are kept (clause heads and guards,
  including patterns and guards inside the body), plus unused private
  clauses. The checker may load a struct module that a pattern names to
  read its fields, as compilation already did to expand the struct. See
  `c:SpecLint.Compiler.pattern_diagnostics/4`.
  """
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

  ## Debug info

  # A module using `GenServer` with a user override (handle_call/3), the
  # untouched defaults (child_spec/1, ...) and a definition whose name is
  # marked generated, compiled in memory under a fresh name and unloaded
  # again. Line 4 is init/1. Debug info is asked for explicitly: the
  # `:debug_info` compiler option may be off in the running VM.
  defp check_debug_info(erl) do
    name = Module.concat(SpecLintDebugInfoProbe, "P#{System.unique_integer([:positive])}")

    source = """
    defmodule #{inspect(name)} do
      @compile {:debug_info, true}
      use GenServer
      def init(state), do: {:ok, state}
      def handle_call(message, _from, state), do: {:reply, message, state}
      def generated_fun(x), do: x
    end
    """

    quoted =
      source
      |> Code.string_to_quoted!()
      |> Macro.prewalk(fn
        {:generated_fun, meta, args} when is_list(args) ->
          {:generated_fun, [generated: true] ++ meta, args}

        other ->
          other
      end)

    try do
      [{^name, binary}] = Code.compile_quoted(quoted, "nofile")
      check_debug_info_chunk(erl, name, binary)
    after
      :code.delete(name)
      :code.purge(name)
    end
  end

  defp check_debug_info_chunk(erl, name, binary) do
    case :beam_lib.chunks(binary, [:debug_info]) do
      {:ok, {^name, [debug_info: {:debug_info_v1, :elixir_erl, data}]}} ->
        case erl.debug_info(:elixir_v1, name, data, []) do
          {:ok, %{definitions: definitions} = map} when is_list(definitions) ->
            failed_checks(debug_info_checks(definitions, map))

          other ->
            {:error, {:unexpected_debug_info, other}}
        end

      {:ok, {^name, [debug_info: other]}} ->
        {:error, {:unexpected_debug_info_chunk, elem(other, 0), elem(other, 1)}}

      {:error, :beam_lib, reason} ->
        {:error, {:no_debug_info, reason}}
    end
  end

  defp debug_info_checks(definitions, map) do
    meta = fn fun_arity ->
      case List.keyfind(definitions, fun_arity, 0) do
        {_, _kind, meta, _clauses} when is_list(meta) -> meta
        _other -> []
      end
    end

    [
      definitions: Enum.all?(definitions, &definition?/1),
      file: is_binary(Map.get(map, :file)),
      attributes: is_list(Map.get(map, :attributes)),
      line: Keyword.get(meta.({:init, 1}), :line) == 4,
      generated:
        Keyword.get(meta.({:generated_fun, 1}), :generated) == true and
          not Keyword.has_key?(meta.({:init, 1}), :generated),
      from_super:
        Keyword.get(meta.({:child_spec, 1}), :from_super) == false and
          meta.({:handle_call, 3}) != [] and
          not Keyword.has_key?(meta.({:handle_call, 3}), :from_super)
    ]
  end

  defp definition?({{name, arity}, kind, meta, clauses})
       when is_atom(name) and is_integer(arity) and is_list(meta) and is_list(clauses) and
              kind in [:def, :defp, :defmacro, :defmacrop],
       do: Enum.all?(clauses, &clause?/1)

  defp definition?(_definition), do: false

  defp clause?({meta, args, guards, _body}),
    do: is_list(meta) and is_list(args) and is_list(guards)

  defp clause?(_clause), do: false

  ## Typespecs

  # An Erlang module with one type of each kind and one spec, compiled in
  # memory (never loaded); fetch_types/1 and fetch_specs/1 read its debug
  # info. `:nominal` exists from OTP 28 on; a compiler line whose
  # fetch_types/1 does not know it must leave it out, not report it as
  # another kind.
  defp check_typespecs(adapter, typespec) do
    nominal? = String.to_integer(System.otp_release()) >= 28

    expected =
      if nominal? and adapter.nominal_types?(),
        do: [:nominal, :opaque, :type, :typep],
        else: [:opaque, :type, :typep]

    binary = typespec_probe_binary(nominal?)

    with {:ok, fetched} <- fetch(typespec, :fetch_types, binary),
         :ok <- check_fetched_types(fetched, expected),
         {:ok, specs} <- fetch(typespec, :fetch_specs, binary) do
      check_fetched_specs(typespec, specs)
    end
  end

  defp fetch(typespec, function, binary) do
    case apply(typespec, function, [binary]) do
      {:ok, list} when is_list(list) -> {:ok, list}
      other -> {:error, {:"#{function}_failed", other}}
    end
  end

  defp check_fetched_specs(typespec, [{{:f, 0}, [spec]}]) do
    case typespec.spec_to_quoted(:f, spec) do
      {:"::", _, [{:f, _, []}, {:integer, _, []}]} -> :ok
      other -> {:error, {:spec_to_quoted_changed, other}}
    end
  end

  defp check_fetched_specs(_typespec, other), do: {:error, {:spec_shape_changed, other}}

  defp typespec_probe_binary(nominal?) do
    types =
      [t: {:type, :integer}, o: {:opaque, :atom}, p: {:type, :float}] ++
        if(nominal?, do: [n: {:nominal, :binary}], else: [])

    exported = for {name, _} <- types, name != :p, do: {name, 0}
    spec = {:type, 1, :fun, [{:type, 1, :product, []}, {:type, 1, :integer, []}]}

    forms =
      [
        {:attribute, 1, :module, :spec_lint_typespec_probe},
        {:attribute, 1, :export, [f: 0]},
        {:attribute, 1, :export_type, exported}
        | for(
            {name, {kind, builtin}} <- types,
            do: {:attribute, 1, kind, {name, {:type, 1, builtin, []}, []}}
          )
      ] ++
        [
          {:attribute, 1, :spec, {{:f, 0}, [spec]}},
          {:function, 1, :f, 0, [{:clause, 1, [], [], [{:integer, 1, 1}]}]}
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

  ## Chunk decoding

  @doc """
  The checker chunk version the running compiler writes. It is a property
  of the running compiler, not of the Elixir build SpecLint was analysed
  against, so it is read dynamically: an apply keeps Dialyzer from
  specialising the result on the checker version of the Elixir this was
  built with. `:erlang.apply/3` rather than `Kernel.apply/3`: the
  arguments are known but the value must stay open.
  """
  @spec running_checker_version() :: atom()
  def running_checker_version, do: :erlang.apply(:elixir_erl, :checker_version, [])

  @doc """
  Decodes an `ExCk` chunk for a running compiler that writes `running`
  chunks, with an adapter qualified for `qualified` chunks. A chunk is
  accepted only when its version equals `running` and `running` is
  `qualified`; a compiler with another chunk version is never analysed
  with an adapter's copy of the application rule.
  """
  @spec decode_checker_chunk(binary(), atom(), atom()) ::
          {:ok, SpecLint.Compiler.chunk()} | {:error, SpecLint.Compiler.chunk_error()}
  def decode_checker_chunk(bytes, running, qualified)
      when is_binary(bytes) and is_atom(running) do
    if running == qualified do
      decode_qualified(bytes, running)
    else
      {:error, {:unqualified_checker_version, running, qualified}}
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
end
