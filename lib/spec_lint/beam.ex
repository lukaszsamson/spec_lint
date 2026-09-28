defmodule SpecLint.Beam do
  @moduledoc """
  Reads the metadata SpecLint needs from one `.beam` file.

  Every source of information is kept as its own result so a failure is
  recorded rather than mistaken for absence: a module whose `Dbgi` chunk is
  missing has `specs: {:error, :missing_metadata}`, never "no specs".

    * `exck` - the decoded checker chunk, whose version must equal the running
      compiler's `:elixir_erl.checker_version/0`;
    * `specs` and `types` - from `Code.Typespec.fetch_specs/1` and
      `fetch_types/1` on the binary;
    * `debug_info` - the `:elixir_v1` debug info: definitions, the first line
      of each definition, and the source file.
  """

  alias SpecLint.Compiler

  @typedoc "Decoded Elixir debug info."
  @type debug_info :: %{
          definitions: [tuple()],
          lines: %{optional({atom(), arity()}) => pos_integer()},
          file: String.t() | nil
        }

  @typedoc "Why the checker chunk is unavailable."
  @type exck_error :: :missing_chunk | Compiler.chunk_error()

  @type t :: %__MODULE__{
          module: module(),
          path: String.t(),
          md5: binary() | nil,
          exports: [{atom(), arity()}],
          exck: {:ok, Compiler.chunk()} | {:error, exck_error()},
          specs: {:ok, [{{atom(), arity()}, [tuple()]}]} | {:error, :missing_metadata},
          types: {:ok, [tuple()]} | {:error, :missing_metadata},
          debug_info: {:ok, debug_info()} | {:error, term()}
        }

  @enforce_keys [:module, :path]
  defstruct [:module, :path, :md5, :exck, :specs, :types, :debug_info, exports: []]

  @doc """
  Reads `path`. Returns `{:error, reason}` only when the file is not a
  readable BEAM file; missing chunks are recorded in the struct.
  """
  @spec read(Path.t()) :: {:ok, t()} | {:error, term()}
  def read(path) do
    with {:ok, binary} <- read_file(path),
         {:ok, module, exports, exck} <- base_chunks(binary) do
      {:ok,
       %__MODULE__{
         module: module,
         path: Path.expand(path),
         md5: md5(binary),
         exports: Enum.sort(exports),
         exck: decode_exck(exck),
         specs: typespec_result(Code.Typespec.fetch_specs(binary)),
         types: typespec_result(Code.Typespec.fetch_types(binary)),
         debug_info: debug_info(binary, module)
       }}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, binary} -> {:ok, binary}
      {:error, reason} -> {:error, {:file, reason}}
    end
  end

  defp base_chunks(binary) do
    case :beam_lib.chunks(binary, [:exports, ~c"ExCk"], [:allow_missing_chunks]) do
      {:ok, {module, [{:exports, exports}, {~c"ExCk", exck}]}} when is_list(exports) ->
        {:ok, module, exports, exck}

      {:ok, {_module, _chunks}} ->
        {:error, :not_a_beam}

      {:error, :beam_lib, reason} ->
        {:error, {:beam_lib, reason}}
    end
  end

  defp decode_exck(:missing_chunk), do: {:error, :missing_chunk}
  defp decode_exck(bytes) when is_binary(bytes), do: Compiler.decode_checker_chunk(bytes)

  defp typespec_result({:ok, list}), do: {:ok, list}
  defp typespec_result(:error), do: {:error, :missing_metadata}

  defp md5(binary) do
    case :beam_lib.md5(binary) do
      {:ok, {_module, md5}} -> md5
      {:error, :beam_lib, _} -> nil
    end
  end

  defp debug_info(binary, module) do
    case :beam_lib.chunks(binary, [:debug_info]) do
      {:ok, {^module, [debug_info: {:debug_info_v1, backend, data}]}} ->
        elixir_debug_info(backend, module, data)

      {:ok, {^module, [debug_info: _other]}} ->
        {:error, :unsupported_debug_info}

      {:error, :beam_lib, {:missing_chunk, _, _}} ->
        {:error, :missing_debug_info}

      {:error, :beam_lib, reason} ->
        {:error, {:beam_lib, reason}}
    end
  end

  defp elixir_debug_info(backend, module, data) do
    case backend.debug_info(:elixir_v1, module, data, []) do
      {:ok, %{definitions: definitions} = map} ->
        {:ok,
         %{
           definitions: definitions,
           lines: definition_lines(definitions),
           file: Map.get(map, :file)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp definition_lines(definitions) do
    for {fun_arity, _kind, meta, _clauses} <- definitions,
        line = Keyword.get(meta, :line),
        is_integer(line),
        into: %{},
        do: {fun_arity, line}
  end
end
