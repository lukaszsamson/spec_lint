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
      of each definition, the definitions whose metadata marks them
      `generated: true`, the overridable defaults the module did not
      override, the source file, and the `__protocol__`/`__impl__`
      attributes the compiler's type checker reads (`checker_attributes`).

  An overridable default that was not overridden (a `defoverridable`
  definition injected by `use`, such as `GenServer`'s `handle_info/2` or
  `child_spec/1`, with no user definition of the same name and arity) is
  stored by the compiler with `from_super: false` in its definition
  metadata (`elixir_overridable:store_not_overridden/1`). A user-written
  override has no `from_super` key, and a default reached through `super`
  is stored under a hidden private name. `overridable_defaults` lists the
  first kind.
  """

  alias SpecLint.Compiler

  @typedoc "Decoded Elixir debug info."
  @type debug_info :: %{
          definitions: [tuple()],
          lines: %{optional({atom(), arity()}) => pos_integer()},
          generated: [{atom(), arity()}],
          overridable_defaults: [{atom(), arity()}],
          file: String.t() | nil,
          checker_attributes: keyword()
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

  @doc """
  `:beam_lib.chunks/3` on the contents of the file at `path`, never on its
  name. `beam_lib` turns a file name into an atom when it reports an error
  (`not_a_beam_file`, `missing_chunk`, ...), which raises `system_limit` for
  a path longer than 255 characters, so a corrupt BEAM in a deep checkout
  would crash the caller instead of being reported. Error reasons name
  `path` where `beam_lib` would name the file; an unreadable file is
  `{:error, :beam_lib, {:file_error, path, posix}}`.
  """
  @spec chunks(Path.t(), [atom() | charlist()], [:allow_missing_chunks]) ::
          {:ok, {module(), list()}} | {:error, :beam_lib, term()}
  def chunks(path, chunks, options \\ []) do
    case File.read(path) do
      {:ok, binary} ->
        case binary_chunks(binary, chunks, options) do
          {:ok, _} = ok -> ok
          {:error, :beam_lib, reason} -> {:error, :beam_lib, name_file(reason, binary, path)}
        end

      {:error, posix} ->
        {:error, :beam_lib, {:file_error, path, posix}}
    end
  end

  defp binary_chunks(binary, chunks, options) do
    :beam_lib.chunks(binary, chunks, options)
  rescue
    error -> {:error, :beam_lib, {:invalid_beam_file, binary, Exception.message(error)}}
  end

  # beam_lib's error reasons are tuples naming the file first.
  defp name_file(reason, binary, path) do
    reason
    |> Tuple.to_list()
    |> Enum.map(fn element -> if element === binary, do: path, else: element end)
    |> List.to_tuple()
  end

  @doc """
  The identity of the BEAM file at `path` as reports record it: the
  `:beam_lib.md5/1` of its code, and the SHA-256 of its decoded `ExCk`
  checker chunk serialised with `:deterministic` (the raw chunk bytes are
  not deterministic across builds). `beam_lib`'s MD5 leaves the `ExCk`
  chunk out, so two builds whose stored signatures differ can share it;
  the chunk digest tells them apart. Either is `nil` when unavailable.
  """
  @spec identity(Path.t()) :: {String.t() | nil, String.t() | nil}
  def identity(path) do
    case File.read(path) do
      {:ok, binary} -> {binary |> md5() |> hex(), exck_digest(binary)}
      {:error, _reason} -> {nil, nil}
    end
  end

  defp hex(nil), do: nil
  defp hex(bytes), do: Base.encode16(bytes, case: :lower)

  defp exck_digest(binary) do
    with {:ok, {_module, [{~c"ExCk", bytes}]}} when is_binary(bytes) <-
           binary_chunks(binary, [~c"ExCk"], [:allow_missing_chunks]),
         {:ok, term} <- decode_term(bytes) do
      :sha256
      |> :crypto.hash(:erlang.term_to_binary(term, [:deterministic]))
      |> hex()
    else
      _ -> nil
    end
  end

  # Checker chunks contain module atoms that may not exist in this VM yet,
  # so `:safe` cannot be used (as in the compiler's own reader).
  defp decode_term(bytes) do
    {:ok, :erlang.binary_to_term(bytes)}
  rescue
    ArgumentError -> :error
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
  rescue
    _error -> nil
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
           generated: generated_definitions(definitions),
           overridable_defaults: overridable_defaults(definitions),
           file: Map.get(map, :file),
           checker_attributes:
             map |> Map.get(:attributes, []) |> Keyword.take([:__protocol__, :__impl__])
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

  defp overridable_defaults(definitions) do
    for {fun_arity, _kind, meta, _clauses} <- definitions,
        Keyword.get(meta, :from_super) == false,
        do: fun_arity
  end

  defp generated_definitions(definitions) do
    for {fun_arity, _kind, meta, _clauses} <- definitions,
        Keyword.get(meta, :generated) == true,
        do: fun_arity
  end
end
