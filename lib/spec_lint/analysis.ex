defmodule SpecLint.Analysis do
  @moduledoc """
  Analyses one compiled module: reads the BEAM, translates each spec slice
  and compares it with the inferred signature from the checker chunk.

  Scope is exported functions with specs. Macros, protocol dispatch
  functions, `behaviour_info/1` and specs of non-exported functions are
  listed under `out_of_scope` with a reason; they are never silently
  dropped. Nothing in the analysed module is loaded or invoked.
  """

  alias SpecLint.{Beam, Compare, Translate, TypeCache}

  @typedoc "Status of a function or a module."
  @type status :: :compared | {:unsupported, term()} | {:unavailable, term()}

  @typedoc "One spec slice of a function."
  @type slice :: %{
          index: non_neg_integer(),
          spec: tuple(),
          status: status(),
          args: [SpecLint.Bound.t()] | nil,
          return: SpecLint.Bound.t() | nil,
          relations: Compare.relations() | nil
        }

  @typedoc "One analysed function."
  @type function_result :: %{
          mfa: mfa(),
          line: pos_integer() | nil,
          status: status(),
          slices: [slice()],
          inferred: [SpecLint.Compiler.clause()],
          dynamic_probe: Compare.probe() | nil
        }

  @typedoc "Why a spec'd function is outside the analysis scope."
  @type out_of_scope_reason :: :macro | :protocol | :behaviour_info | :not_exported

  @typedoc "Result of `module/2`."
  @type result :: %{
          module: module() | nil,
          path: String.t(),
          status: :ok | {:unavailable, term()} | {:out_of_scope, :erlang_module},
          debug_info: :ok | {:error, term()},
          functions: [function_result()],
          out_of_scope: [%{mfa: mfa(), reason: out_of_scope_reason()}]
        }

  @doc """
  Analyses the module in `beam_path`.

  Options:

    * `:cache` - a `SpecLint.TypeCache` to share across modules of a run.
      When absent, a cache is created for this call and deleted afterwards.
    * `:expand_opaque` - expand other modules' opaque and nominal types
      structurally (default `false`).
  """
  @spec module(Path.t(), keyword()) :: result()
  def module(beam_path, opts \\ []) do
    case Keyword.fetch(opts, :cache) do
      {:ok, %TypeCache{} = cache} ->
        run(beam_path, cache, opts)

      :error ->
        cache = TypeCache.new()

        try do
          run(beam_path, cache, opts)
        after
          TypeCache.delete(cache)
        end
    end
  end

  defp run(beam_path, cache, opts) do
    case Beam.read(beam_path) do
      {:ok, beam} ->
        analyse(beam, cache, opts)

      {:error, reason} ->
        %{
          module: nil,
          path: Path.expand(beam_path),
          status: {:unavailable, reason},
          debug_info: {:error, :not_read},
          functions: [],
          out_of_scope: []
        }
    end
  end

  defp analyse(%Beam{} = beam, cache, opts) do
    base = %{
      module: beam.module,
      path: beam.path,
      status: :ok,
      debug_info: debug_info_status(beam),
      functions: [],
      out_of_scope: []
    }

    cond do
      not elixir_module?(beam.module) ->
        %{base | status: {:out_of_scope, :erlang_module}}

      match?({:error, _}, beam.specs) ->
        {:error, reason} = beam.specs
        %{base | status: {:unavailable, reason}}

      true ->
        :ok = TypeCache.put_module(cache, beam.module, beam.md5, beam.types)
        {:ok, specs} = beam.specs
        context = Translate.context(beam.module, cache, opts)

        {functions, out_of_scope} =
          specs
          |> Enum.sort()
          |> Enum.reduce({[], []}, fn spec, {functions, out} ->
            case classify(spec, beam) do
              {:in_scope, fun_arity, clauses} ->
                {[function(beam, fun_arity, clauses, context) | functions], out}

              {:out_of_scope, mfa, reason} ->
                {functions, [%{mfa: mfa, reason: reason} | out]}
            end
          end)

        %{base | functions: Enum.reverse(functions), out_of_scope: Enum.reverse(out_of_scope)}
    end
  end

  defp elixir_module?(module), do: match?("Elixir." <> _, Atom.to_string(module))

  defp debug_info_status(%Beam{debug_info: {:ok, _}}), do: :ok
  defp debug_info_status(%Beam{debug_info: {:error, reason}}), do: {:error, reason}

  defp classify({{name, arity}, clauses}, %Beam{module: module} = beam) do
    case Atom.to_string(name) do
      # Macro specs are stored under the MACRO- prefixed name with the
      # caller argument prepended; the MFA is reported as stored.
      "MACRO-" <> _macro ->
        {:out_of_scope, {module, name, arity}, :macro}

      _ ->
        cond do
          {name, arity} == {:behaviour_info, 1} ->
            {:out_of_scope, {module, name, arity}, :behaviour_info}

          protocol?(beam) ->
            {:out_of_scope, {module, name, arity}, :protocol}

          {name, arity} not in beam.exports ->
            {:out_of_scope, {module, name, arity}, :not_exported}

          true ->
            {:in_scope, {name, arity}, clauses}
        end
    end
  end

  defp protocol?(%Beam{exck: {:ok, %{mode: :protocol}}}), do: true
  defp protocol?(%Beam{exports: exports}), do: {:__protocol__, 1} in exports

  defp function(%Beam{} = beam, {name, arity} = fun_arity, spec_clauses, context) do
    base = %{
      mfa: {beam.module, name, arity},
      line: line(beam, fun_arity),
      status: :compared,
      slices: [],
      inferred: [],
      dynamic_probe: nil
    }

    case signature(beam, fun_arity) do
      {:ok, clauses} ->
        compare(base, spec_clauses, clauses, arity, context)

      {:error, reason} ->
        slices =
          Enum.with_index(spec_clauses, fn spec, index ->
            %{
              index: index,
              spec: spec,
              status: {:unavailable, reason},
              args: nil,
              return: nil,
              relations: nil
            }
          end)

        %{base | status: {:unavailable, reason}, slices: slices}
    end
  end

  defp compare(base, spec_clauses, clauses, arity, context) do
    translated = Enum.map(spec_clauses, &Translate.slice(&1, context))
    %{slices: relations, dynamic_probe: probe} = Compare.function(translated, clauses, arity)

    slices =
      [spec_clauses, translated, relations]
      |> Enum.zip()
      |> Enum.with_index()
      |> Enum.map(fn
        {{spec, {:ok, slice}, {:ok, rel}}, index} ->
          %{
            index: index,
            spec: spec,
            status: :compared,
            args: slice.args,
            return: slice.return,
            relations: rel
          }

        {{spec, {:unsupported, reason}, _}, index} ->
          %{
            index: index,
            spec: spec,
            status: {:unsupported, reason},
            args: nil,
            return: nil,
            relations: nil
          }
      end)

    status =
      case Enum.find(slices, &(&1.status != :compared)) do
        nil -> :compared
        %{status: status} -> status
      end

    %{base | status: status, slices: slices, inferred: clauses, dynamic_probe: probe}
  end

  defp signature(%Beam{exck: {:error, reason}}, _fun_arity),
    do: {:error, {:checker_chunk, reason}}

  defp signature(%Beam{exck: {:ok, %{exports: exports}}}, fun_arity) do
    case Map.fetch(exports, fun_arity) do
      {:ok, %{sig: {:infer, _domain, [_ | _] = clauses}}} -> {:ok, clauses}
      {:ok, %{sig: {:strong, _domain, _clauses}}} -> {:error, :strong_signature}
      {:ok, %{sig: _}} -> {:error, :no_signature}
      :error -> {:error, :no_signature}
    end
  end

  defp line(%Beam{debug_info: {:ok, %{lines: lines}}}, fun_arity), do: Map.get(lines, fun_arity)
  defp line(%Beam{}, _fun_arity), do: nil
end
