defmodule SpecLint.Issue do
  @moduledoc """
  One finding: a rule ID, an evidence class, a severity, the gating
  prerequisites that were checked, and a structural fingerprint
  (DESIGN.md sections 4 and 9).

  Rules create issues; `SpecLint.Policy` sets `gate` (whether the finding
  would fail CI when it is new) and `SpecLint.Baseline` sets `baseline`
  (whether a baseline acknowledges it). The `details` are presentation
  only; the fingerprint never hashes them. They are kept unrendered
  (`t:text/0`): types in them are printed by `render/1`, which the
  reporters and `--explain` call for the findings they show. Nothing
  before rendering prints a type, so the cost of printing grows with the
  number of rendered findings, not with the number of analysed slices.
  """

  alias SpecLint.{Compiler, Rule}

  @typedoc "Rule ID such as `\"SL001\"`."
  @type rule_id :: String.t()

  @typedoc """
  Evidence class of a finding. The section 3.1 classes, plus `:conflict`
  (a whole slice is disjoint or rejected), `:unexpected_return` (SL006),
  `:hint` (SL004, SL005) and `:unsupported` / `:unavailable` (SL008).
  """
  @type evidence ::
          :conflict
          | :clause_conflict
          | :structured_possible
          | :possible_gradual
          | :possible_domain_escape
          | :possible_input_approximate
          | :whole_kind_possible
          | :unexpected_return
          | :hint
          | :unsupported
          | :unavailable

  @typedoc """
  The unrendered value of one detail line (see `render/1`):

    * a string, rendered as it is;
    * `{:type, descr}` - a type, printed through the compiler adapter
      (`SpecLint.Compiler.to_string/1`);
    * `{:spec, name, spec}` - one spec clause, printed as
      `name(args) :: return` (`SpecLint.Rule.spec_string/2`);
    * `{:join_unique, texts, separator}` - each text rendered, repeated
      renderings dropped (first occurrence kept), joined by `separator`;
    * a list of texts, rendered and concatenated.
  """
  @type text ::
          String.t()
          | {:type, Compiler.descr()}
          | {:spec, atom(), tuple()}
          | {:join_unique, [text()], String.t()}
          | [text()]

  @typedoc "How a finding is printed. Never decides gating."
  @type severity :: :error | :warning | :info | :hint

  @typedoc "Outcome of one gating prerequisite."
  @type prerequisite_state :: :met | :blocked | :unchecked

  @typedoc "One gating prerequisite and its outcome."
  @type prerequisite :: {atom(), prerequisite_state()}

  @typedoc """
  Baseline decision: `:new`, `:baselined` (acknowledged by a baseline
  finding or inventory entry) or `:expired` (acknowledged by an entry whose
  `expires` date has passed, so it counts as new).
  """
  @type baseline_decision :: :new | :baselined | :expired

  @type t :: %__MODULE__{
          rule: rule_id(),
          name: atom(),
          module: module(),
          mfa: mfa() | nil,
          slice: non_neg_integer() | nil,
          clause: non_neg_integer() | nil,
          evidence: evidence(),
          severity: severity(),
          file: String.t() | nil,
          line: pos_integer() | nil,
          message: String.t(),
          details: [{String.t(), text()}],
          prerequisites: [prerequisite()],
          data: map(),
          fingerprint: String.t() | nil,
          gate: boolean(),
          baseline: baseline_decision()
        }

  @enforce_keys [:rule, :name, :module, :evidence, :severity, :message]
  defstruct [
    :rule,
    :name,
    :module,
    :evidence,
    :severity,
    :message,
    :fingerprint,
    :file,
    :line,
    mfa: nil,
    slice: nil,
    clause: nil,
    details: [],
    prerequisites: [],
    data: %{},
    gate: false,
    baseline: :new
  ]

  @doc """
  Renders one detail value (`t:text/0`) to a string. This is where the
  types of a finding are printed; call it only for findings that are
  shown.
  """
  @spec render(text()) :: String.t()
  def render(text) when is_binary(text), do: text
  def render({:type, descr}), do: Compiler.to_string(descr)
  def render({:spec, name, spec}), do: Rule.spec_string(name, spec)

  def render({:join_unique, texts, separator}),
    do: texts |> Enum.map(&render/1) |> Enum.uniq() |> Enum.join(separator)

  def render(texts) when is_list(texts), do: Enum.map_join(texts, &render/1)

  @doc "The issue's details with every value rendered (`render/1`)."
  @spec rendered_details(t()) :: [{String.t(), String.t()}]
  def rendered_details(%__MODULE__{details: details}),
    do: for({label, text} <- details, do: {label, render(text)})

  @doc "Whether every prerequisite is met or unchecked (none is blocked)."
  @spec prerequisites_met?(t()) :: boolean()
  def prerequisites_met?(%__MODULE__{prerequisites: prerequisites}),
    do: Enum.all?(prerequisites, fn {_name, state} -> state != :blocked end)

  @doc "The prerequisites that blocked gating."
  @spec blocked(t()) :: [atom()]
  def blocked(%__MODULE__{prerequisites: prerequisites}),
    do: for({name, :blocked} <- prerequisites, do: name)

  @doc "Whether the issue fails the run: it gates and no baseline acknowledges it."
  @spec blocking?(t()) :: boolean()
  def blocking?(%__MODULE__{gate: gate, baseline: baseline}),
    do: gate and baseline in [:new, :expired]

  @doc """
  The subject of the issue as text: `Mod.fun/arity`, or the module name for
  a module-level issue.
  """
  @spec subject(t()) :: String.t()
  def subject(%__MODULE__{mfa: {module, name, arity}}), do: mfa_string({module, name, arity})
  def subject(%__MODULE__{module: module}), do: inspect(module)

  @doc "Formats an MFA as `Mod.fun/arity`."
  @spec mfa_string(mfa()) :: String.t()
  def mfa_string({module, name, arity}), do: "#{inspect(module)}.#{name}/#{arity}"

  @doc "Sort key: file, line, subject, rule, slice, clause."
  @spec sort_key(t()) ::
          {String.t(), non_neg_integer(), String.t(), rule_id(), integer(), integer()}
  def sort_key(%__MODULE__{} = issue) do
    {issue.file || "", issue.line || 0, subject(issue), issue.rule, issue.slice || -1,
     issue.clause || -1}
  end

  @doc "Sorts issues deterministically (`sort_key/1`)."
  @spec sort([t()]) :: [t()]
  def sort(issues), do: Enum.sort_by(issues, &sort_key/1)
end
