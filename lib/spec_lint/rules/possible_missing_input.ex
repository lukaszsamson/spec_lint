defmodule SpecLint.Rules.PossibleMissingInput do
  @moduledoc """
  `SL004 possible_missing_input` (DESIGN.md section 4), off by default.

  A hint, per function: the union of the inferred clause domains (as
  argument tuples) accepts shapes outside the union of the spec slice
  domains (their upper bounds). Functions with an untranslated slice are
  skipped.
  """

  @behaviour SpecLint.Rule

  alias SpecLint.{Compiler, Rule}

  @impl true
  @spec id() :: String.t()
  def id, do: "SL004"

  @impl true
  @spec name() :: :possible_missing_input
  def name, do: :possible_missing_input

  @impl true
  @spec default_severity() :: :off
  def default_severity, do: :off

  @impl true
  @spec summary() :: String.t()
  def summary, do: "the implementation accepts inputs outside the spec domain"

  @impl true
  @spec available?() :: true
  def available?, do: true

  @impl true
  @spec check_function(Rule.function_context()) :: [SpecLint.Issue.t()]
  def check_function(%{function: function} = context) do
    compared? = context.slices != [] and Enum.all?(context.slices, &(&1.evidence != nil))

    if compared? and function.inferred != [] do
      inferred =
        function.inferred
        |> Enum.map(fn {args, _return} ->
          args |> Enum.map(&Compiler.upper_bound/1) |> Compiler.tuple()
        end)
        |> Compiler.union_all()

      spec =
        context.slices
        |> Enum.map(fn %{slice: slice} -> slice.args |> Enum.map(& &1.hi) |> Compiler.tuple() end)
        |> Compiler.union_all()

      outside = Compiler.difference(inferred, spec)

      if Compiler.empty?(outside), do: [], else: [issue(context, outside)]
    else
      []
    end
  end

  defp issue(context, outside) do
    Rule.function_issue(__MODULE__, context,
      inferred: :all,
      evidence: :hint,
      message: "the implementation accepts inputs the spec does not declare",
      details: [
        {"accepted outside the spec", Compiler.to_string(outside)},
        {"evidence", "hint (signature backend)"}
      ]
    )
  end
end
