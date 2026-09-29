defmodule SpecLint.CompilerProbeTest do
  # Capability probes at preflight (Milestone 2): every compiler internal the
  # adapter depends on is probed, and a missing or changed internal fails
  # preflight, which makes a CI run incomplete (exit 2). Each test swaps one
  # internal for a stub that delegates to the real module except for the
  # simulated change; failed/1 checks the probe named in the failure and
  # that a CI run with that preflight is incomplete with exit 2.
  #
  # The probes run through the running compiler's adapter (@adapter). The
  # Descr stubs that depend on a compiler line's encoding are pinned per
  # adapter (`@tag adapter: ...`, Milestone 3); the others run on both.
  use ExUnit.Case, async: false

  import SpecLint.TestHelpers

  alias Module.Types.Descr
  alias SpecLint.{Compiler, Config, Project, Run}
  alias SpecLint.Compiler.{BuildIdentity, V120, V121}
  alias SpecLint.Fixtures.Compare

  @adapter Compiler.running_adapter()

  @moduletag :tmp_dir

  # A one-module project for failed/1's CI run.
  setup %{tmp_dir: dir} do
    ebin = Path.join(dir, "ebin")
    File.mkdir_p!(ebin)
    File.cp!(beam_path(Compare), Path.join(ebin, "#{Compare}.beam"))
    project = Project.from_ebins([{:fx, ebin}], dir)
    Process.put(:probe_project, project)
    %{project: project}
  end

  test "every probe passes on the running compiler" do
    internals = @adapter.internals()

    for probe <- @adapter.capability_probes() do
      assert @adapter.probe(probe, internals) == :ok, "probe #{probe}"
    end

    assert {:ok, capabilities} = @adapter.preflight(internals)
    assert capabilities.adapter_id == "#{System.version()}+#{System.build_info()[:revision]}"

    revision = String.slice(System.build_info()[:revision], 0, 7)
    recorded = Map.fetch!(@adapter.qualified_builds(), revision)
    assert capabilities.build_digest == BuildIdentity.combined(recorded)
    assert {:ok, ^recorded} = BuildIdentity.running_digests()
  end

  test "every qualified revision has recorded build digests of the same modules" do
    [modules | others] =
      for adapter <- Compiler.adapters() do
        builds = adapter.qualified_builds()
        assert Enum.sort(Map.keys(builds)) == Enum.sort(adapter.qualified_revisions())
        for {_revision, digests} <- builds, do: Enum.sort(Map.keys(digests))
      end
      |> Enum.concat()

    assert Enum.all?(others, &(&1 == modules))
    assert "Elixir.Module.Types.Expr" in modules
    assert "elixir_overridable" in modules
    assert Enum.all?(modules, &BuildIdentity.pinned?/1)
  end

  test "the 1.20 adapter is qualified for the 1.20.4 release only" do
    assert V120.qualified_revisions() == ["759443e"]
    assert V120.version_requirement() == "~> 1.20.4"
    assert V120.qualified_checker_version() == :elixir_checker_v8
    assert V121.qualified_checker_version() == :elixir_checker_v10
    assert V120.max_clauses() == V121.max_clauses()
  end

  test "a configured adapter takes precedence over the selection" do
    other = Enum.find(Compiler.adapters(), &(&1 != @adapter))
    Application.put_env(:spec_lint, :compiler_adapter, other)

    try do
      assert Compiler.adapter() == other
      assert Compiler.running_adapter() == @adapter
      assert {:error, {:unsupported_elixir, _version, _requirement}} = Compiler.preflight()
    after
      Application.delete_env(:spec_lint, :compiler_adapter)
    end
  end

  test "the qualified revisions are the fork revision and upstream 648b2a9" do
    assert V121.qualified_revisions() == ["c24c235", "648b2a9"]
    assert V121.check_build("1.21.0-dev", "648b2a9") == :ok
    assert V121.check_build("1.21.0-dev", "648b2a94934664cfd2c788348d02d799c68faa69") == :ok
    assert V121.check_build("1.21.0-dev", "c24c235") == :ok

    assert {:error, {:unqualified_revision, "25fa668", _}} =
             V121.check_build("1.21.0-dev", "25fa668")
  end

  test "a missing internal module fails preflight" do
    internals = %{@adapter.internals() | descr: SpecLint.NoSuchDescr}

    assert @adapter.preflight(internals) ==
             {:error, {:missing_compiler_modules, [SpecLint.NoSuchDescr]}}
  end

  describe "compiler identity" do
    # A build of a qualified revision whose checker code differs (the
    # reviewer's reproduction: c24c235 with the for-into fix reverted
    # reports revision c24c235 and passed every other probe).
    setup %{tmp_dir: dir} do
      ebins =
        for {ebin, index} <- Enum.with_index(BuildIdentity.running_ebins()) do
          copy = Path.join([dir, "build", "app#{index}", "ebin"])
          File.mkdir_p!(copy)

          for path <- Path.wildcard(Path.join(ebin, "*.beam")),
              BuildIdentity.pinned?(Path.basename(path, ".beam")),
              do: File.cp!(path, Path.join(copy, Path.basename(path)))

          copy
        end

      %{ebins: ebins}
    end

    test "an unchanged copy of the running build passes", %{ebins: ebins} do
      assert @adapter.probe(:compiler_identity, %{@adapter.internals() | build_ebins: ebins}) ==
               :ok
    end

    test "a changed checker module", %{ebins: ebins} do
      {:ok, _module, stub} =
        :compile.forms(
          [{:attribute, 1, :module, :"Elixir.Module.Types.Expr"}, {:attribute, 1, :export, []}],
          [:binary]
        )

      [elixir_ebin | _] = ebins
      File.write!(Path.join(elixir_ebin, "Elixir.Module.Types.Expr.beam"), stub)
      revision = String.slice(System.build_info()[:revision], 0, 7)

      assert failed(build_ebins: ebins) ==
               {:compiler_identity, {:build_differs, revision, ["Elixir.Module.Types.Expr"]}}
    end

    test "a missing pinned module", %{ebins: ebins} do
      [elixir_ebin | _] = ebins
      File.rm!(Path.join(elixir_ebin, "elixir_overridable.beam"))

      assert {:compiler_identity, {:build_differs, _revision, ["elixir_overridable"]}} =
               failed(build_ebins: ebins)
    end

    test "a digest does not depend on the directory the build is in", %{ebins: [elixir_ebin | _]} do
      [running | _] = BuildIdentity.running_ebins()
      beam = "Elixir.Module.Types.Descr.beam"

      assert BuildIdentity.module_digest(Path.join(elixir_ebin, beam)) ==
               BuildIdentity.module_digest(Path.join(running, beam))
    end
  end

  describe "Module.Types.Descr" do
    test "a missing function" do
      stub = stub(Descr, drop: [bdd_to_dnf: 1])

      assert failed(descr: stub) ==
               {:descr_exports, {:missing_descr_functions, [bdd_to_dnf: 1]}}
    end

    @tag adapter: V121
    test "a changed map field encoding (the optional flag)" do
      stub =
        stub(Descr,
          drop: [closed_map: 1],
          body:
            quote do
              def closed_map(pairs) do
                Descr.closed_map(
                  Enum.map(pairs, fn
                    {key, {value, optional?}} when is_atom(key) -> {key, {value, not optional?}}
                    other -> other
                  end)
                )
              end
            end
        )

      assert {:descr_encoding, {:checks_failed, failed}} = failed(descr: stub)
      assert :closed_map in failed
    end

    test "a changed tuple layout" do
      stub =
        stub(Descr,
          drop: [tuple: 1],
          body:
            quote do
              def tuple(elements), do: Descr.open_tuple(elements)
            end
        )

      assert failed(descr: stub) == {:descr_encoding, {:checks_failed, [:closed_tuple]}}
    end

    test "a changed bitmap bit" do
      stub =
        stub(Descr,
          drop: [pid: 0],
          body:
            quote do
              def pid, do: Descr.port()
            end
        )

      # On 1.20 term() is also expanded from the bits (audit-1.20.4.md).
      failed = if @adapter == V120, do: [:bitmap, :term_expansion], else: [:bitmap]
      assert failed(descr: stub) == {:descr_encoding, {:checks_failed, failed}}
    end

    test "changed semantics: covariant functions" do
      stub =
        stub(Descr,
          drop: [fun: 2],
          body:
            quote do
              def fun(args, return),
                do: Descr.fun(Enum.map(args, fn _ -> Descr.term() end), return)
            end
        )

      assert {:descr_semantics, {:checks_failed, failed}} = failed(descr: stub)
      assert :fun_contravariance in failed
    end

    test "a changed printer option" do
      stub =
        stub(Descr,
          drop: [to_quoted_string: 2],
          body:
            quote do
              def to_quoted_string(descr, _opts), do: Descr.to_quoted_string(descr, [])
            end
        )

      assert failed(descr: stub) == {:descr_semantics, {:checks_failed, [:quoted_dynamic]}}
    end
  end

  describe "Module.Types.Descr on 1.20: map fields and domains" do
    @describetag adapter: V120

    test "a changed map field encoding (the not_set() marker)" do
      stub =
        stub(Descr,
          drop: [if_set: 1],
          body:
            quote do
              def if_set(type), do: Map.delete(Descr.if_set(type), :optional)
            end
        )

      assert {:descr_encoding, {:checks_failed, failed}} = failed(descr: stub)
      assert :optional_marker in failed
      assert :closed_map in failed
    end

    test "a changed optional flag on fields" do
      stub =
        stub(Descr,
          drop: [closed_map: 1],
          body:
            quote do
              def closed_map(pairs) do
                Descr.closed_map(
                  Enum.map(pairs, fn
                    {key, %{optional: 1} = value} when is_atom(key) ->
                      {key, Map.delete(value, :optional)}

                    {key, value} when is_atom(key) ->
                      {key, Descr.if_set(value)}

                    other ->
                      other
                  end)
                )
              end
            end
        )

      assert {:descr_encoding, {:checks_failed, failed}} = failed(descr: stub)
      assert :closed_map in failed
    end

    test "the bitstring key domain renamed" do
      stub =
        stub(Descr,
          drop: [to_domain_keys: 1],
          body:
            quote do
              def to_domain_keys(descr) do
                for key <- Descr.to_domain_keys(descr),
                    do: if(key == :bitstring, do: :bitstring_no_binary, else: key)
              end
            end
        )

      assert failed(descr: stub) == {:descr_encoding, {:checks_failed, [:bitstring_domain]}}
    end
  end

  describe "Module.Types.Descr on 1.20: term() and recursive nodes" do
    @describetag adapter: V120

    test "term() is no longer the union of its kinds' top types" do
      stub =
        stub(Descr,
          drop: [non_empty_list: 2],
          body:
            quote do
              def non_empty_list(:term, :term),
                do: Descr.non_empty_list(Descr.integer(), Descr.empty_list())

              def non_empty_list(element, tail), do: Descr.non_empty_list(element, tail)
            end
        )

      assert failed(descr: stub) == {:descr_encoding, {:checks_failed, [:term_expansion]}}
    end

    test "recursive nodes appear" do
      stub =
        stub(Descr,
          body:
            quote do
              def recursive(equations), do: equations
            end
        )

      assert failed(descr: stub) == {:descr_encoding, {:checks_failed, [:no_recursive_nodes]}}
    end
  end

  describe "Module.Types.Descr: unfold/1 and recursive nodes (audit row 8)" do
    @describetag adapter: V121

    test "unfold/1 no longer expands term()" do
      stub =
        stub(Descr,
          drop: [unfold: 1],
          body:
            quote do
              def unfold(:term), do: %{}
              def unfold(other), do: Descr.unfold(other)
            end
        )

      assert failed(descr: stub) == {:descr_encoding, {:checks_failed, [:unfold]}}
    end

    test "a changed recursive node layout" do
      stub =
        stub(Descr,
          drop: [recursive: 1],
          body:
            quote do
              def recursive(equations),
                do: Map.new(Descr.recursive(equations), fn {k, node} -> {k, %{node: node}} end)
            end
        )

      assert failed(descr: stub) == {:descr_encoding, {:checks_failed, [:recursive_node]}}
    end
  end

  describe "Module.Types.Descr: other encodings and semantics" do
    test "atoms no longer stored as a union set" do
      stub =
        stub(Descr,
          drop: [atom: 1],
          body:
            quote do
              def atom(atoms),
                do: SpecLint.Compiler.difference(Descr.atom(), Descr.atom([:__none__ | atoms]))
            end
        )

      assert {:descr_encoding, {:checks_failed, failed}} = failed(descr: stub)
      assert :atom_union in failed
    end

    test "dynamic no longer a :dynamic field" do
      stub =
        stub(Descr,
          drop: [dynamic: 1],
          body:
            quote do
              def dynamic(descr), do: %{gradual: Descr.dynamic(descr)}
            end
        )

      assert {:descr_encoding, {:checks_failed, failed}} = failed(descr: stub)
      assert :dynamic in failed
    end

    test "changed gradual bounds" do
      stub =
        stub(Descr,
          drop: [lower_bound: 1],
          body:
            quote do
              def lower_bound(descr), do: Descr.upper_bound(descr)
            end
        )

      assert failed(descr: stub) == {:descr_semantics, {:checks_failed, [:gradual_bounds]}}
    end

    test "changed domain keys" do
      stub =
        stub(Descr,
          drop: [to_domain_keys: 1],
          body:
            quote do
              def to_domain_keys(descr), do: Descr.to_domain_keys(descr) -- [:integer]
            end
        )

      assert failed(descr: stub) == {:descr_semantics, {:checks_failed, [:domain_keys]}}
    end

    test "changed atom_fetch/1" do
      stub =
        stub(Descr,
          drop: [atom_fetch: 1],
          body:
            quote do
              def atom_fetch(descr) do
                case Descr.atom_fetch(descr) do
                  {:finite, atoms} -> {:finite, Enum.map(atoms, &to_string/1)}
                  other -> other
                end
              end
            end
        )

      assert failed(descr: stub) == {:descr_semantics, {:checks_failed, [:atom_fetch]}}
    end
  end

  describe ":elixir_erl debug info (the :elixir_v1 contract SpecLint.Beam reads)" do
    test "missing debug_info/4" do
      stub = stub(:elixir_erl, drop: [debug_info: 4])
      assert failed(erl: stub) == {:debug_info, {:missing_functions, [{stub, :debug_info, 4}]}}
    end

    test "overridable defaults no longer marked from_super: false" do
      stub = debug_info_stub(quote(do: fn meta -> Keyword.delete(meta, :from_super) end))
      assert failed(erl: stub) == {:debug_info, {:checks_failed, [:from_super]}}
    end

    test "generated definitions no longer marked" do
      stub = debug_info_stub(quote(do: fn meta -> Keyword.delete(meta, :generated) end))
      assert failed(erl: stub) == {:debug_info, {:checks_failed, [:generated]}}
    end

    test "a definition line under another key" do
      stub =
        debug_info_stub(
          quote do
            fn meta -> [{:location, Keyword.get(meta, :line)} | Keyword.delete(meta, :line)] end
          end
        )

      assert failed(erl: stub) == {:debug_info, {:checks_failed, [:line]}}
    end

    test "a changed definition tuple" do
      stub =
        stub(:elixir_erl,
          drop: [debug_info: 4],
          body:
            quote do
              def debug_info(kind, module, data, opts) do
                with {:ok, map} <- :elixir_erl.debug_info(kind, module, data, opts) do
                  {:ok,
                   %{
                     map
                     | definitions: for({fa, k, m, c} <- map.definitions, do: {fa, k, m, c, []})
                   }}
                end
              end
            end
        )

      assert {:debug_info, {:checks_failed, failed}} = failed(erl: stub)
      assert :definitions in failed
    end
  end

  describe ":elixir_erl.checker_version/0" do
    test "missing" do
      assert failed(erl: stub(:elixir_erl, drop: [checker_version: 0])) ==
               {:checker_version, :no_checker_version}
    end

    test "a new chunk version" do
      stub =
        stub(:elixir_erl,
          drop: [checker_version: 0],
          body:
            quote do
              def checker_version, do: :elixir_checker_v11
            end
        )

      assert failed(erl: stub) ==
               {:checker_version,
                {:unsupported_checker_version, :elixir_checker_v11,
                 @adapter.qualified_checker_version()}}
    end
  end

  describe "the ExCk chunk layout" do
    test "a renamed signature key", %{tmp_dir: dir} do
      sample =
        sample_chunk(dir, fn exports -> for {fa, info} <- exports, do: {fa, rename(info)} end)

      assert failed(exck_sample: sample) == {:checker_chunk, :no_stored_signatures}
    end

    test "a changed clause shape", %{tmp_dir: dir} do
      sample =
        sample_chunk(dir, fn exports ->
          for {fa, %{sig: {kind, domain, clauses}} = info} <- exports do
            {fa, %{info | sig: {kind, domain, Enum.map(clauses, &Tuple.insert_at(&1, 2, :pure))}}}
          end
        end)

      assert failed(exck_sample: sample) == {:checker_chunk, :clause_shape_changed}
    end

    test "exports as a map", %{tmp_dir: dir} do
      sample = sample_chunk(dir, &Map.new/1)
      assert failed(exck_sample: sample) == {:checker_chunk, :malformed_sample_chunk}
    end

    test "another chunk version in the sample", %{tmp_dir: dir} do
      path =
        rebuild_beam(Compare, dir, fn chunks ->
          {~c"ExCk", bytes} = List.keyfind(chunks, ~c"ExCk", 0)
          {_version, contents} = :erlang.binary_to_term(bytes)
          bytes = :erlang.term_to_binary({:elixir_checker_v11, contents})
          List.keyreplace(chunks, ~c"ExCk", 0, {~c"ExCk", bytes})
        end)

      assert failed(exck_sample: path) ==
               {:checker_chunk,
                {:checker_version_mismatch, :elixir_checker_v11,
                 @adapter.qualified_checker_version()}}
    end

    test "an export key that is no longer {name, arity}", %{tmp_dir: dir} do
      sample =
        sample_chunk(dir, fn exports ->
          for {{f, a}, info} <- exports, do: {{f, a, :def}, info}
        end)

      assert failed(exck_sample: sample) == {:checker_chunk, :export_shape_changed}
    end

    test "signatures the decoder does not read", %{tmp_dir: dir} do
      # The same function listed twice: the decoder keeps one entry per
      # function, so it no longer accounts for every stored signature.
      sample =
        sample_chunk(dir, fn exports ->
          signed = Enum.find(exports, &match?({_, %{sig: {_, _, _}}}, &1))
          exports ++ [signed]
        end)

      assert failed(exck_sample: sample) == {:checker_chunk, :decoder_disagrees}
    end

    test "no chunk", %{tmp_dir: dir} do
      path = rebuild_beam(Compare, dir, &List.keydelete(&1, ~c"ExCk", 0))
      assert {:checker_chunk, {:no_sample_chunk, _}} = failed(exck_sample: path)
    end
  end

  describe "Module.Types.Apply.remote_apply/7 and the apply_infer/2 copy" do
    test "a larger clause cutoff" do
      stub =
        stub(Module.Types.Apply,
          drop: [remote_apply: 7],
          body:
            quote do
              # The compiler's cutoff raised to 32: all 17 clauses apply.
              def remote_apply(
                    {:infer, _domain, clauses},
                    _mod,
                    _fun,
                    _args,
                    _expr,
                    _stack,
                    context
                  )
                  when length(clauses) in 17..32 do
                {used, context} =
                  Enum.reduce(clauses, {[], context}, fn {_args, return}, {acc, context} ->
                    {[return | acc], context}
                  end)

                {used |> Enum.reduce(&SpecLint.Compiler.union/2) |> Descr.dynamic(), context}
              end

              def remote_apply(info, mod, fun, args, expr, stack, context),
                do: RealApply.remote_apply(info, mod, fun, args, expr, stack, context)
            end
        )

      assert failed(apply: stub) == {:apply_infer, {:checks_failed, [:over_cutoff]}}
    end

    test "a result no longer wrapped in dynamic()" do
      stub =
        stub(Module.Types.Apply,
          drop: [remote_apply: 7],
          body:
            quote do
              def remote_apply(info, mod, fun, args, expr, stack, context) do
                {type, context} =
                  RealApply.remote_apply(info, mod, fun, args, expr, stack, context)

                {Descr.upper_bound(type), context}
              end
            end
        )

      assert {:apply_infer, {:checks_failed, failed}} = failed(apply: stub)
      assert :selection in failed
    end

    test "a missing entry point" do
      stub = stub(Module.Types.Apply, drop: [remote_apply: 7])

      assert failed(apply: stub) ==
               {:apply_infer, {:missing_functions, [{stub, :remote_apply, 7}]}}
    end
  end

  describe "the pattern and guard checker" do
    test "a checker that no longer reports a contradictory guard" do
      stub =
        stub(Module.Types,
          drop: [warnings: 6],
          body:
            quote do
              def warnings(_module, _file, _attrs, _defs, _no_warn_undefined, _cache), do: []
            end
        )

      assert failed(types: stub) == {:pattern_checker, {:unexpected_diagnostics, []}}
    end

    test "diagnostics under another module tag" do
      stub =
        stub(Module.Types,
          drop: [warnings: 6],
          body:
            quote do
              def warnings(module, file, attrs, defs, no_warn_undefined, cache) do
                for {Module.Types.Pattern, warning, location} <-
                      Module.Types.warnings(module, file, attrs, defs, no_warn_undefined, cache),
                    do: {Module.Types.Guard, warning, location}
              end
            end
        )

      assert failed(types: stub) == {:pattern_checker, {:unexpected_diagnostics, []}}
    end

    test "a checker that no longer reports an unused private clause" do
      stub =
        stub(Module.Types,
          drop: [warnings: 6],
          body:
            quote do
              def warnings(module, file, attrs, defs, no_warn_undefined, cache) do
                for {Module.Types.Pattern, _, _} = warning <-
                      Module.Types.warnings(module, file, attrs, defs, no_warn_undefined, cache),
                    do: warning
              end
            end
        )

      assert failed(types: stub) == {:pattern_checker, {:unexpected_diagnostics, [{{:g, 1}, 2}]}}
    end

    test "a changed pattern entry point arity" do
      stub = stub(Module.Types.Pattern, drop: [of_head: 8])

      assert failed(pattern: stub) ==
               {:pattern_checker, {:missing_functions, [{stub, :of_head, 8}]}}
    end
  end

  describe "Code.Typespec.fetch_types/1" do
    # 1.21 reports OTP 28 -nominal types as :nominal.
    @tag adapter: V121
    test "a kind no longer reported" do
      stub =
        stub(Code.Typespec,
          drop: [fetch_types: 1],
          body:
            quote do
              def fetch_types(module) do
                with {:ok, types} <- Code.Typespec.fetch_types(module) do
                  {:ok,
                   for(
                     {kind, type} <- types,
                     do: {if(kind == :nominal, do: :type, else: kind), type}
                   )}
                end
              end
            end
        )

      assert {:typespec_kinds, {:type_kinds_changed, _}} = failed(typespec: stub)
    end

    # 1.20.4 leaves -nominal types out (audit-1.20.4.md row 18): one that
    # starts reporting them fails the probe.
    @tag adapter: V120
    test "nominal types no longer left out" do
      stub =
        stub(Code.Typespec,
          drop: [fetch_types: 1],
          body:
            quote do
              def fetch_types(module) do
                with {:ok, types} <- Code.Typespec.fetch_types(module),
                     do: {:ok, [{:nominal, {:n, {:type, 1, :binary, []}, []}} | types]}
              end
            end
        )

      assert {:typespec_kinds, {:type_kinds_changed, kinds}} = failed(typespec: stub)
      assert :nominal in kinds
    end

    @tag adapter: V120
    test "the running Code.Typespec leaves nominal types out" do
      refute V120.nominal_types?()
      assert @adapter.probe(:typespec_kinds, @adapter.internals()) == :ok
    end
  end

  describe "Code.Typespec.fetch_specs/1 and spec_to_quoted/2" do
    test "fetch_specs/1 missing" do
      stub = stub(Code.Typespec, drop: [fetch_specs: 1])

      assert failed(typespec: stub) ==
               {:typespec_kinds, {:missing_functions, [{stub, :fetch_specs, 1}]}}
    end

    test "a changed spec shape" do
      stub =
        stub(Code.Typespec,
          drop: [fetch_specs: 1],
          body:
            quote do
              def fetch_specs(module) do
                with {:ok, specs} <- Code.Typespec.fetch_specs(module),
                     do: {:ok, for({fa, [spec]} <- specs, do: {fa, spec})}
              end
            end
        )

      assert {:typespec_kinds, {:spec_shape_changed, _}} = failed(typespec: stub)
    end

    test "a changed quoted spec" do
      stub =
        stub(Code.Typespec,
          drop: [spec_to_quoted: 2],
          body:
            quote do
              def spec_to_quoted(name, spec),
                do: {:when, [], [Code.Typespec.spec_to_quoted(name, spec), []]}
            end
        )

      assert {:typespec_kinds, {:spec_to_quoted_changed, _}} = failed(typespec: stub)
    end
  end

  describe "Mix.Compilers.Elixir.read_manifest/1" do
    test "missing" do
      stub = stub(Mix.Compilers.Elixir, drop: [read_manifest: 1])

      assert failed(manifest: stub) ==
               {:compile_manifest, {:missing_functions, [{stub, :read_manifest, 1}]}}
    end

    test "a changed sentinel for an unreadable manifest" do
      stub =
        stub(Mix.Compilers.Elixir,
          drop: [read_manifest: 1],
          body:
            quote do
              def read_manifest(_path), do: {%{}, %{}}
            end
        )

      assert failed(manifest: stub) ==
               {:compile_manifest, {:unreadable_manifest_result, {%{}, %{}}}}
    end
  end

  test "a probe that raises fails instead of crashing preflight" do
    stub =
      stub(Descr,
        drop: [bdd_to_dnf: 1],
        body:
          quote do
            def bdd_to_dnf(_bdd), do: raise("changed")
          end
      )

    assert failed(descr: stub) == {:descr_encoding, {:raised, "changed"}}
  end

  describe "end to end" do
    test "a failed probe makes a CI run incomplete (exit 2) and reports it locally",
         %{project: project} do
      stub = stub(Module.Types, drop: [warnings: 6])
      preflight = @adapter.preflight(%{@adapter.internals() | types: stub})
      assert {:error, {:capability_probe_failed, :pattern_checker, _}} = preflight

      config = %Config{baseline: "missing.json"}
      assert {:ok, ci} = Run.execute(project, config, ci: true, preflight: preflight)
      assert ci.completion == :incomplete
      assert ci.exit_code == 2
      assert [reason] = ci.completion_reasons
      assert reason =~ "unsupported compiler"
      assert reason =~ "capability_probe_failed"
      assert reason =~ "pattern_checker"

      assert {:ok, local} = Run.execute(project, config, preflight: preflight)
      assert local.completion == :incomplete
      assert local.issues == []
    end

    test "through the configured adapter, as the Mix task runs it", %{project: project} do
      previous = Application.get_env(:spec_lint, :compiler_adapter)
      Application.put_env(:spec_lint, :compiler_adapter, __MODULE__.BrokenApplyAdapter)

      try do
        assert {:error, {:capability_probe_failed, :apply_infer, _}} = Compiler.preflight_once()
        assert {:ok, run} = Run.execute(project, %Config{baseline: "missing.json"}, ci: true)
        assert run.exit_code == 2
        assert run.completion == :incomplete
      after
        if previous,
          do: Application.put_env(:spec_lint, :compiler_adapter, previous),
          else: Application.delete_env(:spec_lint, :compiler_adapter)
      end
    end
  end

  defmodule NoApply do
    @moduledoc false
  end

  defmodule BrokenApplyAdapter do
    @moduledoc false
    # The qualified adapter probing a compiler whose Module.Types.Apply lost
    # remote_apply/7. Only preflight/0 is reached: the run stops there.
    alias SpecLint.CompilerProbeTest.NoApply

    @spec preflight() :: {:ok, SpecLint.Compiler.capabilities()} | {:error, term()}
    def preflight do
      adapter = SpecLint.Compiler.running_adapter()
      adapter.preflight(%{adapter.internals() | apply: NoApply})
    end
  end

  # The first failing probe, as {probe, detail}. A CI run of the one-module
  # project with that preflight is incomplete and exits 2, naming the probe.
  defp failed(overrides) do
    internals = Map.merge(@adapter.internals(), Map.new(overrides))

    case @adapter.preflight(internals) do
      {:error, {:capability_probe_failed, probe, detail}} = preflight ->
        project = Process.get(:probe_project)
        config = %Config{baseline: "missing.json"}
        assert {:ok, run} = Run.execute(project, config, ci: true, preflight: preflight)
        assert run.exit_code == 2
        assert run.completion == :incomplete
        assert [reason] = run.completion_reasons
        assert reason =~ "capability_probe_failed"
        assert reason =~ Atom.to_string(probe)
        {probe, detail}

      other ->
        flunk("expected a failed probe, got #{inspect(other)}")
    end
  end

  # :elixir_erl whose :elixir_v1 debug info has every definition's
  # metadata passed through the quoted one-argument function `fun`.
  defp debug_info_stub(fun) do
    stub(:elixir_erl,
      drop: [debug_info: 4],
      body:
        quote do
          def debug_info(kind, module, data, opts) do
            with {:ok, map} <- :elixir_erl.debug_info(kind, module, data, opts) do
              fun = unquote(fun)

              {:ok,
               %{
                 map
                 | definitions:
                     for({fa, k, meta, c} <- map.definitions, do: {fa, k, fun.(meta), c})
               }}
            end
          end
        end
    )
  end

  # A module delegating every exported function of `real` to it, except the
  # `drop`ped ones; `body` adds replacements.
  defp stub(real, opts) do
    drop = Keyword.get(opts, :drop, [])
    name = Module.concat(__MODULE__.Stub, "S#{System.unique_integer([:positive])}")

    delegates =
      for {fun, arity} <- real.module_info(:exports),
          fun not in [:module_info, :__info__],
          not String.starts_with?(Atom.to_string(fun), "MACRO-"),
          {fun, arity} not in drop do
        args = Macro.generate_arguments(arity, __MODULE__)

        quote do
          def unquote(fun)(unquote_splicing(args)),
            do: unquote(real).unquote(fun)(unquote_splicing(args))
        end
      end

    prelude =
      quote do
        alias Module.Types.Apply, as: RealApply
        alias Module.Types.Descr
      end

    body = [prelude | delegates] ++ List.wrap(opts[:body])
    {:module, ^name, _binary, _} = Module.create(name, body, Macro.Env.location(__ENV__))
    name
  end

  defp rename(%{sig: sig} = info), do: info |> Map.delete(:sig) |> Map.put(:signature, sig)
  defp rename(info), do: info

  # The BEAM of Compare with its ExCk exports transformed.
  defp sample_chunk(dir, fun) do
    rebuild_beam(Compare, dir, fn chunks ->
      {~c"ExCk", bytes} = List.keyfind(chunks, ~c"ExCk", 0)
      {version, contents} = :erlang.binary_to_term(bytes)
      contents = %{contents | exports: fun.(contents.exports)}

      List.keyreplace(
        chunks,
        ~c"ExCk",
        0,
        {~c"ExCk", :erlang.term_to_binary({version, contents})}
      )
    end)
  end
end
