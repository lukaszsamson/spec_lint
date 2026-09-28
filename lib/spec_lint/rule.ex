defmodule SpecLint.Rule do
  @moduledoc """
  Behaviour of a SpecLint rule (DESIGN.md section 4), plus helpers shared
  by the rules in `SpecLint.Rules`.

  A rule turns raw per-slice relations (`SpecLint.Compare`) and evidence
  (`SpecLint.Evidence`) into `SpecLint.Issue` values. Rules never decide
  gating: they record which gating prerequisites were met, and
  `SpecLint.Policy` decides. Rules never print; `details` are rendered by
  the reporters.
  """

  alias SpecLint.{Analysis, Baseline, Bound, Compiler, Evidence, Issue}

  @typedoc "One slice of a function with its evidence (`nil` when not compared)."
  @type slice_context :: %{
          slice: Analysis.slice(),
          evidence: Evidence.classification() | nil
        }

  @typedoc "What a rule sees for one function in scope."
  @type function_context :: %{
          module: Analysis.result(),
          function: Analysis.function_result(),
          file: String.t() | nil,
          slices: [slice_context()],
          severity: Issue.severity()
        }

  @typedoc "What a rule sees for one module."
  @type module_context :: %{
          module: Analysis.result(),
          file: String.t() | nil,
          severity: Issue.severity()
        }

  @doc "The rule ID, such as `\"SL001\"`."
  @callback id() :: Issue.rule_id()

  @doc "The rule name, such as `:return_conflict`."
  @callback name() :: atom()

  @doc "Severity when the configuration does not set one; `:off` disables the rule."
  @callback default_severity() :: Issue.severity() | :off

  @doc "One-line description."
  @callback summary() :: String.t()

  @doc "Whether the rule's analysis backend is available in this build."
  @callback available?() :: boolean()

  @doc "Issues for one function in scope."
  @callback check_function(function_context()) :: [Issue.t()]

  @doc "Issues for one module (module-level coverage). Optional."
  @callback check_module(module_context()) :: [Issue.t()]

  @optional_callbacks check_module: 1

  @doc """
  Builds an issue for `rule` from a function context. `attrs` sets the
  evidence, message, details, prerequisites, slice and clause, and
  `:inferred` selects the inferred clauses hashed into the fingerprint:
  `:contributing` (default, the clauses the application rule selected for
  the slice), `:all`, or a list of clause indexes.
  """
  @spec function_issue(module(), function_context(), keyword()) :: Issue.t()
  def function_issue(rule, context, attrs) do
    %{function: function} = context
    slice = attrs[:slice] && Enum.at(function.slices, attrs[:slice])
    inferred = inferred_for(function, slice, Keyword.get(attrs, :inferred, :contributing))

    fingerprint =
      Baseline.fingerprint(%{
        rule: rule.id(),
        mfa: function.mfa,
        slice: attrs[:slice],
        clause: attrs[:clause],
        spec: slice && slice.spec,
        args: slice && slice.args,
        return: slice && slice.return,
        inferred: inferred,
        extra: attrs[:fingerprint_extra]
      })

    {module, _name, _arity} = function.mfa

    %Issue{
      rule: rule.id(),
      name: rule.name(),
      module: module,
      mfa: function.mfa,
      slice: attrs[:slice],
      clause: attrs[:clause],
      evidence: Keyword.fetch!(attrs, :evidence),
      severity: context.severity,
      file: context.file,
      line: function.line,
      message: Keyword.fetch!(attrs, :message),
      details: Keyword.get(attrs, :details, []),
      prerequisites: Keyword.get(attrs, :prerequisites, []),
      data: Keyword.get(attrs, :data, %{}),
      fingerprint: fingerprint
    }
  end

  defp inferred_for(_function, slice, :contributing) do
    case slice do
      %{relations: %{contributing: contributing}} ->
        Enum.map(contributing, &{&1.index, {&1.args, &1.return}})

      _ ->
        []
    end
  end

  defp inferred_for(function, _slice, :all), do: Enum.with_index(function.inferred, &{&2, &1})

  defp inferred_for(function, _slice, indexes) when is_list(indexes),
    do: for(index <- indexes, do: {index, Enum.at(function.inferred, index)})

  @doc """
  SL001 prerequisites for a compared slice (DESIGN.md section 4): no
  `unsupported` loss, no overlap tag (certain or unknown) and no arrow in
  the spec return.
  """
  @spec sl001_prerequisites(Analysis.slice()) :: [Issue.prerequisite()]
  def sl001_prerequisites(%{args: args, return: return, relations: relations}) do
    unsupported? =
      Enum.any?([return | args], &(:unsupported_construct in Bound.loss_kinds(&1)))

    [
      {:no_unsupported_loss, state(not unsupported?)},
      {:no_overlap, state(not relations.overlap? and not relations.overlap_unknown?)},
      {:no_arrow_in_return, state(not arrow_return?(return))}
    ]
  end

  @doc "`:met` for `true`, `:blocked` for `false`."
  @spec state(boolean()) :: Issue.prerequisite_state()
  def state(true), do: :met
  def state(false), do: :blocked

  @doc "Whether the upper bound of a spec return contains a function type."
  @spec arrow_return?(Bound.t()) :: boolean()
  def arrow_return?(%Bound{hi: hi}), do: Enum.any?(Compiler.components(hi), &(&1.kind == :fun))

  @doc "Prints one spec clause as `name(args) :: return`."
  @spec spec_string(atom(), tuple()) :: String.t()
  def spec_string(name, spec) do
    name |> Code.Typespec.spec_to_quoted(spec) |> Macro.to_string()
  rescue
    _ -> inspect(spec)
  end

  @doc "Prints a slice domain from its argument bounds (upper bounds)."
  @spec domain_string([Bound.t()]) :: String.t()
  def domain_string(args), do: "(" <> Enum.map_join(args, ", ", &Compiler.to_string(&1.hi)) <> ")"

  @doc "Prints an inferred clause as `(args) -> return`."
  @spec clause_string(Compiler.clause()) :: String.t()
  def clause_string({args, return}) do
    "(" <>
      Enum.map_join(args, ", ", &Compiler.to_string/1) <> ") -> " <> Compiler.to_string(return)
  end

  @doc "`exact` or `approximate (loss kinds)` for a slice's translation."
  @spec translation_string(Analysis.slice()) :: String.t()
  def translation_string(%{args: args, return: return}) do
    case [return | args] |> Enum.flat_map(&Bound.loss_kinds/1) |> Enum.uniq() |> Enum.sort() do
      [] -> "translation exact"
      kinds -> "translation approximate: " <> Enum.join(kinds, ", ")
    end
  end

  @doc "The spec's function name for a context."
  @spec function_name(function_context()) :: atom()
  def function_name(%{function: %{mfa: {_module, name, _arity}}}), do: name
end
