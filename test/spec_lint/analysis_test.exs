defmodule SpecLint.AnalysisTest do
  use ExUnit.Case, async: true

  import SpecLint.TestHelpers

  alias SpecLint.{Analysis, Beam, TypeCache}
  alias SpecLint.Fixtures.{Compare, Proto}

  @moduletag :tmp_dir

  defp rebuild(module, tmp_dir, fun) do
    {:ok, binary} = File.read(beam_path(module))
    {:ok, ^module, chunks} = :beam_lib.all_chunks(binary)
    {:ok, rebuilt} = :beam_lib.build_module(fun.(chunks))
    path = Path.join(tmp_dir, "#{module}.beam")
    File.write!(path, rebuilt)
    path
  end

  test "exported functions with specs are compared; macros and privates are out of scope" do
    result = Analysis.module(beam_path(Compare))
    assert result.status == :ok
    assert result.debug_info == :ok
    assert Enum.all?(result.functions, &(&1.status == :compared))
    assert Enum.all?(result.functions, &is_integer(&1.line))

    assert %{mfa: {Compare, :"MACRO-twice", 2}, reason: :macro} in result.out_of_scope
    assert %{mfa: {Compare, :helper, 1}, reason: :not_exported} in result.out_of_scope
    refute Enum.any?(result.functions, &match?(%{mfa: {_, :helper, 1}}, &1))
  end

  test "protocol module: dispatch functions have no inferred signature and are out of scope" do
    unconsolidated = Path.join(Mix.Project.compile_path(), "#{Proto}.beam")

    for path <- Enum.uniq([beam_path(Proto), unconsolidated]) do
      {:ok, beam} = Beam.read(path)
      {:ok, chunk} = beam.exck
      assert chunk.mode == :protocol
      # Unconsolidated protocols store no signature; consolidation stores a
      # strong one. Neither is an inferred signature to compare against.
      refute match?(%{sig: {:infer, _, _}}, chunk.exports[{:describe, 1}])

      result = Analysis.module(path)
      assert result.functions == []
      assert %{mfa: {Proto, :describe, 1}, reason: :protocol} in result.out_of_scope
    end
  end

  test "checker chunk version mismatch makes every function unavailable", %{tmp_dir: tmp_dir} do
    fake = :erlang.term_to_binary({:elixir_checker_v1, %{exports: [], mode: :elixir}})

    path =
      rebuild(Compare, tmp_dir, fn chunks ->
        List.keyreplace(chunks, ~c"ExCk", 0, {~c"ExCk", fake})
      end)

    {:ok, beam} = Beam.read(path)
    expected = :elixir_erl.checker_version()
    assert beam.exck == {:error, {:checker_version_mismatch, :elixir_checker_v1, expected}}
    assert {:ok, [_ | _]} = beam.specs

    result = Analysis.module(path)
    assert [_ | _] = result.functions

    for function <- result.functions do
      assert function.status ==
               {:unavailable,
                {:checker_chunk, {:checker_version_mismatch, :elixir_checker_v1, expected}}}

      assert Enum.all?(function.slices, &match?({:unavailable, _}, &1.status))
    end
  end

  test "missing checker chunk is recorded, not treated as no signature", %{tmp_dir: tmp_dir} do
    path = rebuild(Compare, tmp_dir, &List.keydelete(&1, ~c"ExCk", 0))
    {:ok, beam} = Beam.read(path)
    assert beam.exck == {:error, :missing_chunk}

    result = Analysis.module(path)

    assert Enum.all?(
             result.functions,
             &(&1.status == {:unavailable, {:checker_chunk, :missing_chunk}})
           )
  end

  test "missing debug info is missing metadata, never 'no specs'", %{tmp_dir: tmp_dir} do
    path = rebuild(Compare, tmp_dir, &List.keydelete(&1, ~c"Dbgi", 0))
    {:ok, beam} = Beam.read(path)
    assert beam.specs == {:error, :missing_metadata}
    assert beam.types == {:error, :missing_metadata}
    assert beam.debug_info == {:error, :missing_debug_info}

    result = Analysis.module(path)
    assert result.status == {:unavailable, :missing_metadata}
    assert result.debug_info == {:error, :missing_debug_info}
  end

  test "unreadable files are unavailable", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "garbage.beam")
    File.write!(path, "not a beam")
    assert {:error, _} = Beam.read(path)
    assert %{status: {:unavailable, _}, functions: []} = Analysis.module(path)
  end

  test "Erlang modules are out of scope" do
    path = List.to_string(:code.which(:lists))
    assert %{status: {:out_of_scope, :erlang_module}} = Analysis.module(path)
  end

  test "a shared type cache memoises modules with their beam digest" do
    cache = TypeCache.new()

    try do
      result = Analysis.module(beam_path(SpecLint.Fixtures.Types), cache: cache)
      assert result.status == :ok
      assert is_binary(TypeCache.md5(cache, SpecLint.Fixtures.Remote))

      assert {:ok, %{kind: :opaque}} =
               TypeCache.fetch_type(cache, SpecLint.Fixtures.Remote, :secret, 0)

      assert {:error, :type_not_found} =
               TypeCache.fetch_type(cache, SpecLint.Fixtures.Remote, :nope, 0)

      assert {:error, :module_not_found} = TypeCache.fetch_type(cache, SpecLint.Missing, :t, 0)
    after
      TypeCache.delete(cache)
    end
  end
end
