defmodule SpecLint.Rules.PossibleMissingReturn do
  @moduledoc """
  `SL002 possible_missing_return` (DESIGN.md sections 3.1 and 4).

  Reports a slice whose evidence class (`SpecLint.Evidence`) says the
  inferred return may contain alternatives the spec omits:
  `structured_possible`, `possible_gradual`, `possible_domain_escape`,
  `possible_input_approximate` or `whole_kind_possible`. A slice where
  `SL001` fires at slice level is left to `SL001`, and a `no_return()`
  spec to `SL006`.

  SL002 is informational (Phase 0 and Phase 1 rerun decisions): it is
  reported in both profiles and gates only under `--warnings-as-errors`.
  Its prerequisites (the SL001 ones plus the class `structured_possible`)
  are still recorded, for `--explain` and for a future revisit.
  """

  @behaviour SpecLint.Rule

  alias SpecLint.{Rule, Rules.ReturnConflict}

  @reported [
    :structured_possible,
    :possible_gradual,
    :possible_domain_escape,
    :possible_input_approximate,
    :whole_kind_possible
  ]

  @impl true
  @spec id() :: String.t()
  def id, do: "SL002"

  @impl true
  @spec name() :: :possible_missing_return
  def name, do: :possible_missing_return

  @impl true
  @spec default_severity() :: :warning
  def default_severity, do: :warning

  @impl true
  @spec summary() :: String.t()
  def summary, do: "the inferred return may include alternatives the spec omits"

  @impl true
  @spec available?() :: true
  def available?, do: true

  @impl true
  @spec check_function(Rule.function_context()) :: [SpecLint.Issue.t()]
  def check_function(context) do
    name = Rule.function_name(context)

    for %{slice: slice, evidence: %{class: class} = evidence} <- context.slices,
        class in @reported,
        not slice.relations.spec_return_empty?,
        not ReturnConflict.slice_conflict?(slice) do
      Rule.function_issue(__MODULE__, context,
        slice: slice.index,
        evidence: class,
        message: message(class),
        details: [
          {"spec", {:spec, name, slice.spec}},
          {"inferred extra", extra_text(slice, evidence)},
          {"slice", Rule.domain_text(slice.args)},
          {"evidence", "#{class} (signature backend, #{Rule.translation_string(slice)})"}
        ],
        prerequisites:
          Rule.sl001_prerequisites(slice) ++
            [{:structured_possible, Rule.state(class == :structured_possible)}],
        data: %{reasons: Enum.map(evidence.reasons, &inspect/1)}
      )
    end
  end

  defp message(:structured_possible),
    do: "Review whether the spec should include this alternative."

  defp message(:possible_gradual),
    do: "Possible missing alternative; supported only by gradual (dynamic) clause returns."

  defp message(:possible_domain_escape),
    do: "Possible missing alternative; some contributing clauses accept inputs outside the spec."

  defp message(:possible_input_approximate),
    do: "Possible missing alternative; the spec's inputs were widened by translation."

  defp message(:whole_kind_possible),
    do: "Possible missing alternative of a whole base kind; often imprecise inference."

  # The counted (present) components when there are any, else the whole
  # extra of the slice. Unrendered: repeated printings of the components
  # are dropped when the finding is rendered, as before the rendering was
  # deferred.
  defp extra_text(slice, evidence) do
    counted =
      (evidence.components ++ Enum.flat_map(evidence.clauses, & &1.components))
      |> Enum.filter(&(&1.present_in_contributing? and &1.label != :unknown))
      |> Enum.map(&{:type, &1.descr})

    case counted do
      [] -> {:type, slice.relations.extra}
      types -> {:join_unique, types, " or "}
    end
  end
end
