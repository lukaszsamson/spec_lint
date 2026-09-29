defmodule SpecLint.Reachability do
  @moduledoc """
  The compiler's own verdict behind the `clause_reachable` prerequisite of
  an SL001 clause conflict (DESIGN.md section 3.1 step 7: "the compiler did
  not already flag the clause unreachable").

  The checker chunk does not record that verdict. A clause whose guard
  contradicts its pattern (`def g(:b = x) when is_integer(x)`) is stored
  with its pattern domain and its body's return, so the stored signature
  cannot tell it from a live clause, and `SpecLint.Compare.shadowed/1`
  misses it because no earlier clause covers it. `check/2` therefore
  re-runs the compiler's type checker (`SpecLint.Compiler.pattern_diagnostics/4`)
  over the debug info of every function with a `clause_conflict` and keeps
  the lines of its pattern and guard diagnostics for that function.

  Stored clauses cannot be mapped back to source clauses (the checker drops
  precise clauses whose return is empty, such as a clause that always
  raises, and merges clauses with equal returns), so
  `SpecLint.Rules.ReturnConflict` blocks every clause conflict of a function
  with any such diagnostic. That over-blocks, and never misses a clause the
  compiler's type checker reports. A dead clause the type checker does not
  report is out of reach: a guard whose contradiction it cannot see (such as
  `x > 5 and x < 3`), a clause only the Erlang compiler reports, or a clause
  quoted with `generated: true`, whose diagnostics the checker suppresses.
  """

  alias SpecLint.{Analysis, Beam, Compiler, Coverage}

  @typedoc """
  The check for one function: the lines of its pattern and guard
  diagnostics (`[]` when the compiler reported none), or why the check
  could not run.
  """
  @type result :: {:ok, [pos_integer() | nil]} | {:error, term()}

  @doc """
  Checks every function of `modules` that has a slice with a
  `clause_conflict` clause in `evidence`, keyed by MFA. Functions without
  one are not checked and are absent from the result.
  """
  @spec check([Analysis.result()], Coverage.evidence_map()) :: %{mfa() => result()}
  def check(modules, evidence) do
    for %{status: :ok} = module <- modules,
        mfas = clause_conflict_functions(module, evidence),
        mfas != [],
        entry <- check_module(module, mfas),
        into: %{},
        do: entry
  end

  defp clause_conflict_functions(module, evidence) do
    for function <- module.functions,
        Enum.any?(function.slices, &clause_conflict?(evidence, function.mfa, &1.index)),
        do: function.mfa
  end

  defp clause_conflict?(evidence, mfa, index) do
    case Map.get(evidence, {mfa, index}) do
      %{clauses: clauses} -> Enum.any?(clauses, &(&1.class == :clause_conflict))
      nil -> false
    end
  end

  defp check_module(module, mfas) do
    fun_arities = for {_module, name, arity} <- mfas, do: {name, arity}

    result =
      case Beam.read(module.path) do
        {:ok, %Beam{debug_info: {:ok, info}}} ->
          definitions = Enum.filter(info.definitions, &(elem(&1, 0) in fun_arities))

          Compiler.pattern_diagnostics(
            module.module,
            info.file,
            info.checker_attributes,
            definitions
          )

        {:ok, %Beam{debug_info: {:error, reason}}} ->
          {:error, {:debug_info, reason}}

        {:error, reason} ->
          {:error, {:beam, reason}}
      end

    for {_module, name, arity} = mfa <- mfas do
      case result do
        {:ok, diagnostics} -> {mfa, {:ok, for({{^name, ^arity}, line} <- diagnostics, do: line)}}
        {:error, reason} -> {mfa, {:error, reason}}
      end
    end
  end
end
