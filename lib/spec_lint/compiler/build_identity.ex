defmodule SpecLint.Compiler.BuildIdentity do
  @moduledoc """
  Content identity of the compiler modules a qualified build is pinned by
  (DESIGN.md section 6, "Compiler identity").

  `System.build_info()[:revision]` comes from `git rev-parse HEAD` when
  Elixir is built, so a build of a qualified commit with local changes
  (a reverted fix, a patched checker) reports the qualified revision. The
  adapter therefore also compares the code of the modules whose behaviour
  determines what SpecLint reads with the digests recorded when the
  revision was qualified (`pinned?/1` names them):

    * `Module.Types` and every `Module.Types.*` module, and
      `Module.ParallelChecker`: inference, the stored signatures and the
      pattern diagnostics;
    * `:elixir_erl` (the checker chunk and the debug info backend),
      `:elixir_def` and `:elixir_overridable` (the definition tuples and
      the `:line`, `:generated` and `:from_super` metadata in debug info);
    * `Code.Typespec` and `Mix.Compilers.Elixir` (typespecs and the
      compile manifest).

  A module's digest is `bench/corpus/toolchain/identity.exs`'s code digest:
  the SHA-256 of its code, atom, string, import and export chunks and its
  literal table, in which literals that mention the directory Elixir was
  built in have it replaced by `$ROOT`. Debug info is left out, so the
  digest does not depend on where the build ran. It does depend on the
  Erlang compiler that built it: these modules have the same digests when
  built with OTP 28.0, 28.3.1 and 28.5.0.1, but other Elixir modules
  (`Kernel`, `:elixir_compiler`, ...) do not, which is why the whole build
  is not pinned. Expansion (`:elixir_expand` and friends) is outside the
  pinned set.

  Files are read with `SpecLint.Beam.chunks/3`, never loaded.
  """

  alias SpecLint.Beam

  @code_chunks [~c"Code", ~c"AtU8", ~c"StrT", ~c"ImpT", ~c"ExpT"]

  @pinned_modules ~w(Elixir.Code.Typespec Elixir.Module.ParallelChecker
                     Elixir.Mix.Compilers.Elixir elixir_def elixir_erl elixir_overridable)

  @typedoc "Pinned module (BEAM basename without `.beam`) to its digest."
  @type digests :: %{optional(String.t()) => String.t()}

  @doc "Whether the module named `name` (a BEAM basename without `.beam`) is pinned."
  @spec pinned?(String.t()) :: boolean()
  def pinned?(name) do
    name in @pinned_modules or name == "Elixir.Module.Types" or
      String.starts_with?(name, "Elixir.Module.Types.")
  end

  @doc """
  The ebin directories of the running Elixir build that hold pinned
  modules: the `elixir` and `mix` applications'.
  """
  @spec running_ebins() :: [String.t()]
  def running_ebins do
    for module <- [Kernel, Mix.Compilers.Elixir],
        path = :code.which(module),
        is_list(path),
        do: path |> List.to_string() |> Path.dirname()
  end

  @doc """
  The digests of the pinned modules found in `ebins`, or `{:error,
  {path, reason}}` for the first one that cannot be read. When a module is
  in several directories, the first directory wins, as on the code path.
  """
  @spec digests([Path.t()]) :: {:ok, digests()} | {:error, {String.t(), term()}}
  def digests(ebins) do
    ebins
    |> Enum.flat_map(fn ebin -> ebin |> Path.join("*.beam") |> Path.wildcard() |> Enum.sort() end)
    |> Enum.filter(&pinned?(Path.basename(&1, ".beam")))
    |> Enum.uniq_by(&Path.basename/1)
    |> Enum.reduce_while({:ok, %{}}, fn path, {:ok, acc} ->
      case module_digest(path) do
        {:ok, digest} -> {:cont, {:ok, Map.put(acc, Path.basename(path, ".beam"), digest)}}
        {:error, reason} -> {:halt, {:error, {path, reason}}}
      end
    end)
  end

  @doc """
  `digests/1` of the running build's ebins, computed once per VM (the
  files of the running build do not change while it runs).
  """
  @spec running_digests() :: {:ok, digests()} | {:error, {String.t(), term()}}
  def running_digests do
    ebins = running_ebins()
    key = {__MODULE__, :running, ebins}

    case :persistent_term.get(key, nil) do
      nil ->
        result = digests(ebins)
        :persistent_term.put(key, result)
        result

      result ->
        result
    end
  end

  @doc """
  The modules whose digests differ between `recorded` and `found`,
  including modules present in only one of them, sorted.
  """
  @spec differing(digests(), digests()) :: [String.t()]
  def differing(recorded, found) do
    (Map.keys(recorded) ++ Map.keys(found))
    |> Enum.uniq()
    |> Enum.reject(&(Map.fetch(recorded, &1) == Map.fetch(found, &1)))
    |> Enum.sort()
  end

  @doc "One SHA-256 over all `digests`, the build digest the reports record."
  @spec combined(digests()) :: String.t()
  def combined(digests) do
    digests
    |> Enum.sort()
    |> Enum.map_join(&"#{elem(&1, 0)} #{elem(&1, 1)}\n")
    |> sha256()
  end

  @doc """
  The code digest of one BEAM file (see the moduledoc): code chunks and
  literal table, with the build root in literals replaced by `$ROOT`. The
  build root is read from the module's own compile information (its
  `source`), so the digest is the same wherever the build was made or
  installed.
  """
  @spec module_digest(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def module_digest(path) do
    with {:ok, {_module, chunks}} <- Beam.chunks(path, @code_chunks, [:allow_missing_chunks]),
         {:ok, literals} <- literals(path) do
      {:ok, sha256(:erlang.term_to_binary({chunks, literals}, [:deterministic]))}
    else
      {:error, :beam_lib, reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp literals(path) do
    root = build_root(path)

    case Beam.chunks(path, [~c"LitT"], [:allow_missing_chunks]) do
      {:ok, {_module, [{_, :missing_chunk}]}} -> {:ok, []}
      {:ok, {_module, [{_, table}]}} -> decode_table(table, root)
      {:error, :beam_lib, reason} -> {:error, reason}
    end
  end

  defp decode_table(<<size::32, rest::binary>>, root) do
    <<_count::32, entries::binary>> = if size == 0, do: rest, else: :zlib.uncompress(rest)
    {:ok, decode_literals(entries, root, [])}
  rescue
    error -> {:error, {:literal_table, Exception.message(error)}}
  end

  defp decode_table(_table, _root), do: {:error, :literal_table}

  defp decode_literals(<<len::32, term::binary-size(len), rest::binary>>, root, acc) do
    literal =
      if root == nil or :binary.match(term, root) == :nomatch,
        do: term,
        else:
          term
          |> :erlang.binary_to_term()
          |> inspect(limit: :infinity, printable_limit: :infinity)
          |> String.replace(root, "$ROOT")

    decode_literals(rest, root, [literal | acc])
  end

  defp decode_literals(<<>>, _root, acc), do: Enum.reverse(acc)

  # The directory the Elixir build was made in: the source path recorded in
  # the module's compile information, up to `lib/elixir/` or `lib/mix/`.
  defp build_root(path) do
    with {:ok, {_module, [compile_info: info]}} <- Beam.chunks(path, [:compile_info]),
         source when is_list(source) <- Keyword.get(info, :source),
         [_, root] <- Regex.run(~r{^(.+)/lib/(?:elixir|mix)/(?:lib|src)/}, List.to_string(source)) do
      root
    else
      _ -> nil
    end
  end

  defp sha256(data), do: :sha256 |> :crypto.hash(data) |> Base.encode16(case: :lower)
end
