defmodule SpecLint.CompilerTest do
  use ExUnit.Case, async: true

  alias SpecLint.Compiler, as: C
  alias SpecLint.Compiler.V121

  @pool_size 14

  test "preflight qualifies the running compiler" do
    assert {:ok, capabilities} = C.preflight()
    assert capabilities.adapter == C.adapter()
    assert capabilities.checker_version == :elixir_erl.checker_version()
    assert capabilities.max_clauses == 16
    assert capabilities.signatures
    assert capabilities.revision == System.build_info()[:revision]
    assert capabilities.adapter_id == "#{System.version()}+#{capabilities.revision}"
  end

  test "preflight pins the qualified Elixir revisions" do
    assert V121.check_build(System.version(), System.build_info()[:revision]) == :ok
    qualified = V121.qualified_revisions()

    assert V121.check_build("1.21.0-dev", "deadbee") ==
             {:error, {:unqualified_revision, "deadbee", qualified}}

    assert V121.check_build("1.21.0-dev", nil) ==
             {:error, {:unqualified_revision, nil, qualified}}

    assert {:error, {:unsupported_elixir, "1.20.0", _}} = V121.check_build("1.20.0", "c24c235")
  end

  test "preflight loads Module.Types before probing the body hook" do
    # function_exported?/3 does not load modules; run in a fresh VM where
    # nothing has loaded Module.Types yet.
    script = """
    false = :erlang.module_loaded(Module.Types)
    {:ok, caps} = SpecLint.Compiler.V121.preflight()
    true = :erlang.module_loaded(Module.Types)
    true = caps.body_hook == function_exported?(Module.Types, :warnings, 7)
    IO.write("ok")
    """

    assert {"ok", 0} =
             System.cmd("elixir", ["-pa", Mix.Project.compile_path(), "-e", script],
               stderr_to_stdout: true
             )
  end

  test "to_string prints an empty lazy difference as none()" do
    wide = C.closed_map([], [{[:binary], C.list(C.binary())}])
    narrow = C.closed_map([], [{[:binary], C.non_empty_list(C.binary(), C.empty_list())}])
    empty = C.difference(narrow, wide)
    assert C.empty?(empty)
    assert C.to_string(empty) == "none()"
    assert C.to_string(C.difference(wide, narrow)) != "none()"
  end

  describe "checker chunk decoding" do
    test "a running compiler with an unqualified checker version is rejected" do
      running = :elixir_checker_v11
      bytes = :erlang.term_to_binary({running, %{exports: [], mode: :elixir}})

      assert V121.decode_checker_chunk(bytes, running) ==
               {:error, {:unqualified_checker_version, running, V121.qualified_checker_version()}}
    end

    test "version mismatch" do
      bytes = :erlang.term_to_binary({:elixir_checker_v9, %{exports: [], mode: :elixir}})
      expected = :elixir_erl.checker_version()

      assert C.decode_checker_chunk(bytes) ==
               {:error, {:checker_version_mismatch, :elixir_checker_v9, expected}}
    end

    test "malformed chunks" do
      assert C.decode_checker_chunk("garbage") == {:error, :malformed_chunk}

      bytes = :erlang.term_to_binary({:elixir_erl.checker_version(), :not_a_map})
      assert C.decode_checker_chunk(bytes) == {:error, :malformed_chunk}
    end

    test "current version decodes and normalises signatures" do
      sig = {:infer, nil, [{[C.integer()], C.atom()}]}

      exports = [
        {{:f, 1}, %{sig: sig}},
        {{:g, 0}, %{sig: :none, deprecated: "use f/1"}},
        {{:h, 0}, %{}}
      ]

      bytes = :erlang.term_to_binary({:elixir_erl.checker_version(), %{exports: exports}})
      assert {:ok, chunk} = C.decode_checker_chunk(bytes)
      assert chunk.mode == :elixir
      assert chunk.exports[{:f, 1}] == %{sig: sig, deprecated: nil}
      assert chunk.exports[{:g, 0}] == %{sig: :none, deprecated: "use f/1"}
      assert chunk.exports[{:h, 0}] == %{sig: :none, deprecated: nil}
    end
  end

  describe "apply_infer/2" do
    test "positionwise non-disjoint selection, reverse used order, dynamic wrap" do
      clauses = [
        {[C.integer(), C.atom()], C.atom([:a])},
        {[C.atom(), C.atom()], C.atom([:b])},
        {[C.union(C.integer(), C.float()), C.term()], C.atom([:c])}
      ]

      assert {[2, 0], type} = C.apply_infer(clauses, [C.integer(), C.atom([:x])])
      assert C.gradual?(type)
      assert C.equal?(C.upper_bound(type), C.atom([:a, :c]))
      assert C.apply_infer(clauses, [C.binary(), C.atom()]) == :error
    end

    test "above the clause cutoff the result is dynamic()" do
      clauses = for _ <- 1..(C.max_clauses() + 1), do: {[C.term()], C.atom([:a])}
      assert {used, type} = C.apply_infer(clauses, [C.integer()])
      assert length(used) == C.max_clauses() + 1
      assert type == C.dynamic()

      clauses = Enum.take(clauses, C.max_clauses())
      assert {_, type} = C.apply_infer(clauses, [C.integer()])
      assert C.equal?(C.upper_bound(type), C.atom([:a]))
    end
  end

  describe "differential: apply_infer/2 against the compiler" do
    # Module.Types.Apply.apply_infer/2 is private. Its public caller
    # Module.Types.Apply.remote_apply/7 applies an {:infer, _, clauses}
    # signature through it for any module that has no special-cased remote
    # (the generic remote_apply/5 clause), returning the type on success and
    # marking the context as failed on :error. It does not expose the used
    # clause indexes; those are checked against an independent computation.

    test "30 generated clause sets agree" do
      :rand.seed(:exsss, {2026, 9, 28})
      pool = pool()

      outcomes =
        for set <- 1..30, reduce: %{error: 0, applied: 0, cutoff: 0} do
          acc ->
            arity = :rand.uniform(3)
            count = if rem(set, 5) == 0, do: 17 + :rand.uniform(3), else: :rand.uniform(6)
            clauses = for _ <- 1..count, do: {for(_ <- 1..arity, do: pick(pool)), pick(pool)}

            # Include the all-dynamic probe so cutoff sets are exercised.
            probes = [
              List.duplicate(C.dynamic(), arity) | for(_ <- 1..6, do: random_args(pool, arity))
            ]

            Enum.reduce(probes, acc, &check_case(set, clauses, &1, &2))
        end

      assert outcomes.error > 0
      assert outcomes.applied > 0
      assert outcomes.cutoff > 0
    end
  end

  defp pool do
    [
      C.atom([:a]),
      C.atom([:b]),
      C.atom(),
      C.integer(),
      C.float(),
      C.binary(),
      C.tuple([C.atom([:ok]), C.integer()]),
      C.empty_list(),
      C.list(C.integer()),
      C.dynamic(),
      C.dynamic(C.integer()),
      C.open_map(),
      C.union(C.integer(), C.atom([:a])),
      C.term()
    ]
  end

  defp pick(pool), do: Enum.at(pool, :rand.uniform(@pool_size) - 1)

  defp compiler_apply(clauses, args) do
    stack =
      Module.Types.stack(:dynamic, "nofile", SpecLintDiff, {:f, length(args)}, :all, nil, fn
        _, _, _, _ -> false
      end)

    context = Module.Types.context()
    expr = {{:., [], [SpecLintDiff, :f]}, [line: 1], []}
    sig = {:infer, nil, clauses}

    case Module.Types.Apply.remote_apply(sig, SpecLintDiff, :f, args, expr, stack, context) do
      {_type, %{failed: true}} -> :error
      {type, %{failed: false}} -> {:ok, type}
    end
  end

  defp expected_used(clauses, args) do
    for {{clause_args, _}, index} <- Enum.with_index(clauses),
        Enum.zip(args, clause_args) |> Enum.all?(fn {a, e} -> not C.disjoint?(a, e) end),
        do: index
  end

  defp random_args(pool, arity), do: for(_ <- 1..arity, do: pick(pool))

  defp check_case(set, clauses, args, acc) do
    ours = C.apply_infer(clauses, args)

    case compiler_apply(clauses, args) do
      :error ->
        assert ours == :error, "set #{set}: compiler rejects, copy applies"
        assert expected_used(clauses, args) == []
        Map.update!(acc, :error, &(&1 + 1))

      {:ok, type} ->
        assert {used, our_type} = ours, "set #{set}: copy rejects, compiler applies"
        assert our_type == type
        assert used == Enum.reverse(expected_used(clauses, args))
        key = if length(used) > C.max_clauses(), do: :cutoff, else: :applied
        Map.update!(acc, key, &(&1 + 1))
    end
  end
end
