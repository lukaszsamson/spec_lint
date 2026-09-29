# Prints the path-independent identity of the running Elixir build as JSON.
#
#     /path/to/elixir/bin/elixir bench/corpus/toolchain/identity.exs
#
# Two builds of the same revision in different directories have different
# BEAM files: debug info, and the literals of about 25 modules (`use`
# macros quoted with `location: :keep`, `__ENV__.file`), record the absolute
# build directory. This script hashes what does not depend on it:
#
#   * code_digest - per module, the Code, atom, string, import and export
#     chunks, and the literal table with the build root replaced by "$ROOT"
#     in the literals that contain it (FunT is left out: it hashes the
#     literals it references);
#   * exck_digest - per module, the decoded `ExCk` checker chunk (the stored
#     signatures SpecLint reads), serialised with `:deterministic`, because
#     the raw chunk bytes are not deterministic across builds.
#
# Both builds must set the same SOURCE_DATE_EPOCH, which System.build_info/0
# embeds. Writes nothing.

root = :code.lib_dir(:elixir) |> Path.join("../..") |> Path.expand()
apps = ~w(elixir eex ex_unit iex logger mix)
code_chunks = [~c"Code", ~c"AtU8", ~c"StrT", ~c"ImpT", ~c"ExpT"]

sha256 = fn data -> :crypto.hash(:sha256, data) |> Base.encode16(case: :lower) end
det = &:erlang.term_to_binary(&1, [:deterministic])

# Literals are kept as their external term bytes, except the few that
# mention the build root, which are inspected with the root replaced.
decode_literals = fn
  decode, <<len::32, term::binary-size(len), rest::binary>>, acc ->
    literal =
      if :binary.match(term, root) == :nomatch,
        do: term,
        else:
          term
          |> :erlang.binary_to_term()
          |> inspect(limit: :infinity, printable_limit: :infinity)
          |> String.replace(root, "$ROOT")

    decode.(decode, rest, [literal | acc])

  _decode, <<>>, acc ->
    Enum.reverse(acc)
end

literals = fn beam ->
  case :beam_lib.chunks(beam, [~c"LitT"], [:allow_missing_chunks]) do
    {:ok, {_, [{_, <<size::32, rest::binary>>}]}} ->
      <<_count::32, entries::binary>> = if size == 0, do: rest, else: :zlib.uncompress(rest)
      decode_literals.(decode_literals, entries, [])

    {:ok, {_, [{_, :missing_chunk}]}} ->
      []
  end
end

rows =
  for app <- apps,
      beam <- Path.wildcard(Path.join([root, "lib", app, "ebin", "*.beam"])) |> Enum.sort() do
    charlist = String.to_charlist(beam)
    {:ok, {module, chunks}} = :beam_lib.chunks(charlist, code_chunks, [:allow_missing_chunks])
    code = sha256.(det.({chunks, literals.(charlist)}))

    exck =
      case :beam_lib.chunks(charlist, [~c"ExCk"], [:allow_missing_chunks]) do
        {:ok, {_, [{_, bytes}]}} when is_binary(bytes) ->
          bytes |> :erlang.binary_to_term() |> det.() |> sha256.()

        {:ok, {_, [{_, :missing_chunk}]}} ->
          "none"
      end

    {app, module, code, exck}
  end

digest = fn select ->
  rows |> Enum.map_join("\n", fn row -> Enum.join(select.(row), " ") end) |> sha256.()
end

{:ok, {Module.Types, module_types_md5}} = :beam_lib.md5(:code.which(Module.Types))
info = System.build_info()

otp_version =
  [:code.root_dir(), "releases", System.otp_release(), "OTP_VERSION"]
  |> Path.join()
  |> File.read!()
  |> String.trim()

%{
  "elixir_version" => info.version,
  "revision" => info.revision,
  "build_date" => info.date,
  "otp_release" => System.otp_release(),
  "otp_version" => otp_version,
  "checker_version" => Atom.to_string(:elixir_erl.checker_version()),
  "modules" => length(rows),
  "code_digest" => digest.(fn {app, mod, code, _} -> [app, mod, code] end),
  "exck_digest" => digest.(fn {app, mod, _, exck} -> [app, mod, exck] end),
  "module_types_beam_lib_md5" => Base.encode16(module_types_md5, case: :lower)
}
|> Enum.sort()
|> Enum.map_join(",\n", fn {key, value} -> "  #{inspect(key)}: #{inspect(value)}" end)
|> then(&IO.puts("{\n" <> &1 <> "\n}"))
