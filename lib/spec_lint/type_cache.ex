defmodule SpecLint.TypeCache do
  @moduledoc """
  Per-run memo of type definitions used to resolve user and remote types.

  The cache is an ETS table owned by the process that calls `new/0`. It is
  passed explicitly to every function that needs it; there is no global
  state. Entries are keyed by module and record the BEAM file's MD5, so a
  lookup is memoised by `{module, name, arity}` and beam digest.

  Modules are located with `:code.which/1` (falling back to
  `:code.get_object_code/1` for preloaded or cover-compiled modules). The
  module being analysed may not be on the code path, so callers seed it with
  `put_module/4`.
  """

  @type t :: %__MODULE__{table: :ets.tid()}

  @enforce_keys [:table]
  defstruct [:table]

  @typedoc "A type definition as stored in the debug info."
  @type definition :: %{
          kind: :type | :typep | :opaque | :nominal | atom(),
          params: [term()],
          body: term()
        }

  @typedoc "Why a module's types could not be loaded or a type not found."
  @type error :: :module_not_found | :missing_metadata | :type_not_found

  @doc "Creates a cache owned by the calling process."
  @spec new() :: t()
  def new, do: %__MODULE__{table: :ets.new(__MODULE__, [:set, :public])}

  @doc "Deletes the cache's table."
  @spec delete(t()) :: :ok
  def delete(%__MODULE__{table: table}) do
    true = :ets.delete(table)
    :ok
  end

  @doc """
  Records the types of `module` from an already read BEAM, so they are not
  looked up on the code path. `types` is the result of
  `Code.Typespec.fetch_types/1` (or an error tuple).
  """
  @spec put_module(t(), module(), binary() | nil, {:ok, [tuple()]} | {:error, term()}) :: :ok
  def put_module(%__MODULE__{table: table}, module, md5, types) do
    true = :ets.insert(table, {module, md5, index(types)})
    :ok
  end

  @doc "The BEAM MD5 recorded for `module`, loading it if needed."
  @spec md5(t(), module()) :: binary() | nil
  def md5(%__MODULE__{} = cache, module) do
    {md5, _types} = load(cache, module)
    md5
  end

  @doc "Fetches the definition of `module.name/arity`."
  @spec fetch_type(t(), module(), atom(), arity()) :: {:ok, definition()} | {:error, error()}
  def fetch_type(%__MODULE__{} = cache, module, name, arity) do
    case load(cache, module) do
      {_md5, {:ok, types}} ->
        case Map.fetch(types, {name, arity}) do
          {:ok, definition} -> {:ok, definition}
          :error -> {:error, :type_not_found}
        end

      {_md5, {:error, reason}} ->
        {:error, reason}
    end
  end

  defp load(%__MODULE__{table: table}, module) do
    case :ets.lookup(table, module) do
      [{^module, md5, types}] ->
        {md5, types}

      [] ->
        {md5, types} = read_module(module)
        true = :ets.insert(table, {module, md5, types})
        {md5, types}
    end
  end

  defp read_module(module) do
    case object_code(module) do
      {:ok, binary} ->
        md5 = beam_md5(binary)

        case Code.Typespec.fetch_types(binary) do
          {:ok, types} -> {md5, index({:ok, types})}
          :error -> {md5, {:error, :missing_metadata}}
        end

      :error ->
        {nil, {:error, :module_not_found}}
    end
  end

  defp object_code(module) do
    with path when is_list(path) <- :code.which(module),
         {:ok, binary} <- File.read(path) do
      {:ok, binary}
    else
      _ ->
        case :code.get_object_code(module) do
          {^module, binary, _file} -> {:ok, binary}
          :error -> :error
        end
    end
  end

  defp beam_md5(binary) do
    case :beam_lib.md5(binary) do
      {:ok, {_module, md5}} -> md5
      {:error, :beam_lib, _reason} -> nil
    end
  end

  defp index({:ok, types}) do
    {:ok,
     Map.new(types, fn {kind, {name, body, params}} ->
       {{name, length(params)}, %{kind: kind, params: params, body: body}}
     end)}
  end

  defp index({:error, _} = error), do: error
  defp index(:error), do: {:error, :missing_metadata}
end
