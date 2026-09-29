defmodule SpecLint.Rules.SpecDomainRejected do
  @moduledoc """
  `SL003 spec_domain_rejected` (DESIGN.md section 4).

  The checker's application rule matches no inferred clause on an
  inhabited spec slice (`badapply`), which includes a spec argument
  position disjoint from every inferred domain. The checker would warn on
  every call in this slice. Prerequisites: argument bounds are exact or
  upper bounds (always true for a translated slice, recorded for
  `--explain`) and no overlap tag.
  """

  @behaviour SpecLint.Rule

  alias SpecLint.Rule

  @impl true
  @spec id() :: String.t()
  def id, do: "SL003"

  @impl true
  @spec name() :: :spec_domain_rejected
  def name, do: :spec_domain_rejected

  @impl true
  @spec default_severity() :: :warning
  def default_severity, do: :warning

  @impl true
  @spec summary() :: String.t()
  def summary, do: "no inferred clause accepts the spec's argument domain"

  @impl true
  @spec available?() :: true
  def available?, do: true

  @impl true
  @spec check_function(Rule.function_context()) :: [SpecLint.Issue.t()]
  def check_function(context) do
    name = Rule.function_name(context)

    for %{slice: %{relations: %{badapply?: true} = rel} = slice} <- context.slices do
      disjoint =
        for {:disjoint, index} <- Enum.with_index(rel.domain_relation), do: index

      Rule.function_issue(__MODULE__, context,
        slice: slice.index,
        inferred: :all,
        evidence: :conflict,
        message: "the checker would warn on every call in this slice",
        details: [
          {"spec", {:spec, name, slice.spec}},
          {"slice", Rule.domain_text(slice.args)},
          {"inferred domain", ["(", Rule.types_text(rel.inferred_domain), ")"]},
          {"disjoint positions", disjoint_string(disjoint)},
          {"evidence", "conflict (signature backend, #{Rule.translation_string(slice)})"}
        ],
        prerequisites: [
          {:arguments_upper_bounded, :met},
          {:no_overlap, Rule.state(not rel.overlap? and not rel.overlap_unknown?)}
        ]
      )
    end
  end

  defp disjoint_string([]), do: "none (no clause accepts the whole tuple)"
  defp disjoint_string(indexes), do: Enum.map_join(indexes, ", ", &"argument #{&1 + 1}")
end
