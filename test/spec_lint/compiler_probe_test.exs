defmodule SpecLint.CompilerProbeTest do
  # Capability probes at preflight (Milestone 2): every compiler internal the
  # adapter depends on is probed, and a missing or changed internal fails
  # preflight, which makes a CI run incomplete (exit 2). Each test swaps one
  # internal for a stub that delegates to the real module except for the
  # simulated change.
  use ExUnit.Case, async: false

  import SpecLint.TestHelpers

  alias Module.Types.Descr
  alias SpecLint.{Compiler, Config, Project, Run}
  alias SpecLint.Compiler.V121
  alias SpecLint.Fixtures.Compare

  @moduletag :tmp_dir

  test "every probe passes on the running compiler" do
    internals = V121.internals()

    for probe <- V121.capability_probes() do
      assert V121.probe(probe, internals) == :ok, "probe #{probe}"
    end

    assert {:ok, capabilities} = V121.preflight(internals)
    assert capabilities.adapter_id == "#{System.version()}+#{System.build_info()[:revision]}"
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
    internals = %{V121.internals() | descr: SpecLint.NoSuchDescr}

    assert V121.preflight(internals) ==
             {:error, {:missing_compiler_modules, [SpecLint.NoSuchDescr]}}
  end

  describe "Module.Types.Descr" do
    test "a missing function" do
      stub = stub(Descr, drop: [bdd_to_dnf: 1])

      assert failed(descr: stub) ==
               {:descr_exports, {:missing_descr_functions, [bdd_to_dnf: 1]}}
    end

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

      assert failed(descr: stub) == {:descr_encoding, {:checks_failed, [:bitmap]}}
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
                {:unsupported_checker_version, :elixir_checker_v11, :elixir_checker_v10}}
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

                {used |> Enum.reduce(&Descr.opt_union/2) |> Descr.dynamic(), context}
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

    test "a changed pattern entry point arity" do
      stub = stub(Module.Types.Pattern, drop: [of_head: 8])

      assert failed(pattern: stub) ==
               {:pattern_checker, {:missing_functions, [{stub, :of_head, 8}]}}
    end
  end

  describe "Code.Typespec.fetch_types/1" do
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
    setup %{tmp_dir: dir} do
      ebin = Path.join(dir, "ebin")
      File.mkdir_p!(ebin)
      File.cp!(beam_path(Compare), Path.join(ebin, "#{Compare}.beam"))
      %{project: Project.from_ebins([{:fx, ebin}], dir)}
    end

    test "a failed probe makes a CI run incomplete (exit 2) and reports it locally",
         %{project: project} do
      stub = stub(Module.Types, drop: [warnings: 6])
      preflight = V121.preflight(%{V121.internals() | types: stub})
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
    alias SpecLint.Compiler.V121
    alias SpecLint.CompilerProbeTest.NoApply

    @spec preflight() :: {:ok, SpecLint.Compiler.capabilities()} | {:error, term()}
    def preflight, do: V121.preflight(%{V121.internals() | apply: NoApply})
  end

  # The first failing probe, as {probe, detail}.
  defp failed(overrides) do
    internals = Map.merge(V121.internals(), Map.new(overrides))

    case V121.preflight(internals) do
      {:error, {:capability_probe_failed, probe, detail}} -> {probe, detail}
      other -> flunk("expected a failed probe, got #{inspect(other)}")
    end
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
