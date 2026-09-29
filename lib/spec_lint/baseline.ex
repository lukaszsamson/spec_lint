defmodule SpecLint.Baseline do
  @moduledoc """
  The baseline file: acknowledged findings plus a coverage inventory
  (DESIGN.md section 9).

  ```json
  {"version": 1, "adapter": "1.21.0-dev+c24c235",
   "findings": [{"rule": "SL002", "mfa": "MyApp.Store.lookup/1", "slice": 0,
                 "fingerprint": "sha256:...", "reason": null, ...}],
   "inventory": [{"mfa": "MyApp.Store.lookup/1", "slice": 0,
                  "status": "compared", "translation": "exact"}]}
  ```

  ## Fingerprints

  `fingerprint/1` hashes normalised structural evidence, never printed
  strings, source lines, function bodies or dependency digests:

    * the rule ID, the MFA, the slice index and the clause index;
    * the translated bounds of every argument and of the return, which is
      the spec slice after named-type expansion, through the adapter's
      canonical serialisation (`SpecLint.Compiler.canonical/1`), with their
      loss records normalised: loss kinds with paths that keep only
      structural positions (argument, return, tuple element, list, map
      value, fun argument), without named types, union member indexes or
      map association indexes, sorted and deduplicated; integer intervals
      are sorted;
    * the inferred clauses the finding rests on, canonically serialised;
    * a rule-specific extra term (for `SL008`, the status and reason).

  The raw spec AST is not hashed: it still carries type alias names,
  type variable names and union member order, so renaming a type alias,
  renaming a type variable or reordering a union keeps the fingerprint.
  The translated bounds do not depend on the member order either:
  `SpecLint.Translate` unites a union's members in a fixed order, because
  the compiler fuses two tuple or map literals that differ in one position
  as it unites them, so `{:ok, binary()} | {:error, :timeout} |
  {:error, atom()}` and its reverse would otherwise be different terms.
  Overlapping map associations are read in order (the first wins, as in
  Dialyzer), so reordering those can change the translated type, and then
  the fingerprint.
  A line change or reordering other functions keeps it too, while
  reordering the spec's clauses changes it (the slice index is part of the
  evidence). Refinements the lattice erases (`pos_integer()` against
  `non_neg_integer()` inside a tuple) are not distinguished; integer
  intervals are kept at the top level of each argument and of the return.
  The hash is SHA-256 over `:erlang.term_to_binary(term, [:deterministic])`.

  ## Decisions

  `decide/3` marks every issue `:baselined`, `:expired` or `:new`, and lists
  stale entries. Findings are matched by fingerprint; `SL008` issues by an
  inventory entry with the same subject, slice and status. An `SL008` for
  an unsupported checker chunk (`unsupported_chunk`) is a preflight
  failure and is never acknowledged. Stale entries are warnings, and
  analysis that did not happen never makes an entry stale: a partial or
  incomplete run declares nothing stale, a finding of a rule that did not
  run is not stale, and neither is a finding whose slice or module is now
  unsupported or unavailable. A baseline written by another compiler
  adapter is not applied at all: reconciling it is a deliberate step
  (`mix spec_lint.baseline`).

  A `compared` inventory entry whose slice is no longer in the inventory
  at all (its function or module was deleted, excluded, or its BEAM file
  vanished) is listed with the stale inventory entries in a complete run,
  unless its module is unavailable: the baseline no longer describes the
  project, so regenerate it.

  `expires` must be `null` or an ISO 8601 date (`YYYY-MM-DD`); `parse/2`
  rejects anything else, so a mistyped date cannot suppress a finding
  forever.

  ## Gate state

  Every finding records the gating prerequisites that were blocked when it
  was written (`"blocked"`, a list of names, empty when none was). A
  finding of a rule that gates by its prerequisites (`SL001` `conflict`
  and `clause_conflict`, `SL003`; `SpecLint.Policy`) that was written
  blocked, so reported but not gated, does not acknowledge the same issue
  once its prerequisites are met and it gates: the fingerprint hashes only
  the slice's own evidence, not its siblings, so removing an overlapping
  overload (or translating an unsupported sibling) turns the same
  fingerprint from report-only into gating. Such an issue counts as new,
  and `decide/3` lists its entry under `gate_changed`. An entry without
  `"blocked"` (written by an earlier version) acknowledges as before.

  ## Regeneration

  `build/5` keeps what analysis that did not happen cannot confirm, by the
  same rule `decide/3` uses for staleness: the previous findings of rules
  that did not run, and of slices or modules that are now `unsupported`,
  `unavailable` or `unanalysed`, and the previous `compared` inventory
  entries of modules that are now unavailable as a whole. Regenerating
  while debug info is off, or while an adapter change makes slices
  unavailable, therefore does not drop acknowledgements that come back
  when the analysis does.

  ## Adapter compatibility per entry

  Every finding records the adapter that produced it (`"adapter"`; an
  entry without one inherits the file's). An entry acknowledges an issue
  only when its adapter is the running one: the file-level check is not
  enough, because `build/5` keeps the entries of rules that did not run.
  When those entries come from another adapter, `build/5` keeps them with
  `"pending_reconciliation": true` and their original adapter: they were
  never rechecked by the running compiler, so `decide/3` never counts
  them as baselined, and never declares them stale either. They are listed
  in the decisions as `pending_reconciliation` until a regeneration with
  the rule enabled replaces them (the rule's current findings are written
  afresh) or drops them.
  """

  alias SpecLint.{Bound, Compiler, Issue, Policy}
  alias SpecLint.Report.Json

  @version 1

  # Inventory statuses an acknowledgement applies to (`unanalysed`: a
  # function still exported whose spec was removed,
  # `SpecLint.Coverage.lost_analysis/2`).
  @acknowledged_statuses ["unsupported", "unavailable", "unanalysed"]

  @typedoc "One acknowledged finding."
  @type finding :: %{
          required(String.t()) => String.t() | integer() | nil
        }

  @typedoc "One inventory entry, as stored."
  @type inventory_entry :: %{required(String.t()) => String.t() | integer() | nil}

  @type t :: %__MODULE__{
          path: String.t() | nil,
          version: pos_integer(),
          adapter: String.t() | nil,
          findings: [finding()],
          inventory: [inventory_entry()]
        }

  defstruct path: nil, version: @version, adapter: nil, findings: [], inventory: []

  @typedoc "Structural evidence hashed by `fingerprint/1`."
  @type fingerprint_input :: %{
          optional(:rule) => String.t(),
          optional(:mfa) => mfa() | nil,
          optional(:module) => module() | nil,
          optional(:slice) => non_neg_integer() | nil,
          optional(:clause) => non_neg_integer() | nil,
          optional(:args) => [Bound.t()] | nil,
          optional(:return) => Bound.t() | nil,
          optional(:inferred) => [{non_neg_integer(), Compiler.clause() | nil}],
          optional(:extra) => term()
        }

  @typedoc "Result of `decide/3`."
  @type decisions :: %{
          applied: boolean(),
          reason: nil | :missing | :adapter_mismatch,
          stale_findings: [finding()],
          stale_inventory: [inventory_entry()],
          pending_reconciliation: [finding()],
          gate_changed: [finding()]
        }

  @doc "The baseline file format version."
  @spec version() :: 1
  def version, do: @version

  @doc "Structural fingerprint of a finding (see the moduledoc)."
  @spec fingerprint(fingerprint_input()) :: String.t()
  def fingerprint(input) when is_map(input) do
    term = {
      :spec_lint_fingerprint,
      @version,
      Map.get(input, :rule),
      subject(input),
      Map.get(input, :slice),
      Map.get(input, :clause),
      input |> Map.get(:args) |> bounds(),
      input |> Map.get(:return) |> bound(),
      input |> Map.get(:inferred, []) |> clauses(),
      Map.get(input, :extra)
    }

    digest = :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))
    "sha256:" <> Base.encode16(digest, case: :lower)
  end

  defp subject(%{mfa: {module, name, arity}}), do: {Atom.to_string(module), name, arity}
  defp subject(%{module: module}) when is_atom(module), do: Atom.to_string(module)
  defp subject(_input), do: nil

  defp bounds(nil), do: nil
  defp bounds(bounds), do: Enum.map(bounds, &bound/1)

  defp bound(nil), do: nil

  defp bound(%Bound{} = bound) do
    losses =
      bound.losses
      |> Enum.map(&{&1.kind, structural_path(&1.path)})
      |> Enum.uniq()
      |> Enum.sort()

    integers = bound.integers && Enum.sort(bound.integers)
    {Compiler.canonical(bound.lo), Compiler.canonical(bound.hi), losses, integers}
  end

  # Keeps only the positions of a loss path that do not depend on how the
  # spec is spelled: named types, union member indexes and map association
  # indexes are dropped.
  defp structural_path(path) do
    Enum.flat_map(path, fn
      {:type, _module, _name, _arity} -> []
      {:union, _index} -> []
      {:map_key, _index} -> [:map_key]
      {:map_value, index} when is_integer(index) -> [:map_domain_value]
      segment -> [segment]
    end)
  end

  defp clauses(clauses) do
    for {index, clause} <- clauses do
      case clause do
        {args, return} ->
          {index, Enum.map(args, &Compiler.canonical/1), Compiler.canonical(return)}

        nil ->
          {index, nil}
      end
    end
  end

  @anno_tags [
    :type,
    :var,
    :atom,
    :integer,
    :char,
    :float,
    :string,
    :remote_type,
    :user_type,
    :ann_type,
    :paren_type,
    :op,
    :bin,
    nil
  ]

  @doc """
  Removes annotations (lines, columns) from an Erlang typespec AST, so the
  AST depends only on the spec's structure. Fingerprints do not hash the
  spec AST (see the moduledoc); this is kept for comparing spec ASTs in
  tools and tests.
  """
  @spec strip_annotations(term()) :: term()
  def strip_annotations(tuple) when is_tuple(tuple) and tuple_size(tuple) >= 2 do
    [tag, anno | rest] = Tuple.to_list(tuple)

    if tag in @anno_tags and annotation?(anno),
      do: List.to_tuple([tag, 0 | Enum.map(rest, &strip_annotations/1)]),
      else: tuple |> Tuple.to_list() |> Enum.map(&strip_annotations/1) |> List.to_tuple()
  end

  def strip_annotations(list) when is_list(list), do: Enum.map(list, &strip_annotations/1)
  def strip_annotations(other), do: other

  defp annotation?(anno) when is_integer(anno), do: true
  defp annotation?({line, column}) when is_integer(line) and is_integer(column), do: true
  defp annotation?(anno) when is_list(anno), do: Keyword.keyword?(anno)
  defp annotation?(_anno), do: false

  ## Reading and writing

  @doc """
  Loads the baseline at `path`. `:missing` when the file does not exist,
  `{:error, message}` when it cannot be read or is not a valid version
  #{@version} baseline.
  """
  @spec load(Path.t()) :: {:ok, t()} | :missing | {:error, String.t()}
  def load(path) do
    case File.read(path) do
      {:ok, contents} -> parse(contents, path)
      {:error, :enoent} -> :missing
      {:error, reason} -> {:error, "cannot read baseline #{path}: #{:file.format_error(reason)}"}
    end
  end

  @doc """
  Parses baseline JSON contents. Every finding needs a `sha256:`
  fingerprint and an `expires` that is `null` or an ISO 8601 date; every
  inventory entry must be an object.
  """
  @spec parse(String.t(), Path.t() | nil) :: {:ok, t()} | {:error, String.t()}
  def parse(contents, path \\ nil) do
    case JSON.decode(contents) do
      {:ok, %{"version" => @version, "findings" => findings, "inventory" => inventory} = map}
      when is_list(findings) and is_list(inventory) ->
        with :ok <- validate_entries(findings, inventory, path) do
          {:ok,
           %__MODULE__{
             path: path,
             adapter: Map.get(map, "adapter"),
             findings: findings,
             inventory: inventory
           }}
        end

      {:ok, %{"version" => @version}} ->
        {:error,
         "invalid baseline #{path}: version #{@version} needs \"findings\" and " <>
           "\"inventory\" lists"}

      {:ok, %{"version" => version}} ->
        {:error, "unsupported baseline version #{inspect(version)} in #{path}"}

      {:ok, _other} ->
        {:error, "invalid baseline #{path}: expected version, findings and inventory"}

      {:error, reason} ->
        {:error, "invalid baseline JSON in #{path}: #{inspect(reason)}"}
    end
  end

  defp validate_entries(findings, inventory, path) do
    cond do
      not Enum.all?(findings, &valid_finding?/1) or not Enum.all?(inventory, &is_map/1) ->
        {:error, "invalid baseline #{path}: malformed finding or inventory entry"}

      bad = Enum.find(findings, &(not valid_expires?(&1["expires"]))) ->
        {:error,
         "invalid baseline #{path}: finding #{bad["fingerprint"]} has expires " <>
           "#{inspect(bad["expires"])}; expected null or an ISO 8601 date (YYYY-MM-DD)"}

      true ->
        :ok
    end
  end

  defp valid_finding?(%{"fingerprint" => "sha256:" <> _}), do: true
  defp valid_finding?(_finding), do: false

  defp valid_expires?(nil), do: true
  defp valid_expires?(expires) when is_binary(expires), do: match?({:ok, _}, parse_date(expires))
  defp valid_expires?(_expires), do: false

  # Only the calendar date form YYYY-MM-DD, not the other ISO 8601 forms
  # Date.from_iso8601/1 accepts.
  defp parse_date(<<_::binary-size(10)>> = expires), do: Date.from_iso8601(expires)
  defp parse_date(_expires), do: {:error, :invalid_format}

  @doc """
  Builds the baseline written by `mix spec_lint.baseline` from the current
  reported issues and inventory. Every non-`SL008` issue becomes a finding
  (whether it gates or not, since `--warnings-as-errors` can gate any);
  `SL008` issues are acknowledged through their inventory entries. The
  `reason`, `owner` and `expires` of a previous entry with the same
  fingerprint (or inventory key and status) are kept; new inventory
  acknowledgements get `"initial baseline"`, to be reviewed.

  Each finding records its blocked prerequisites (`"blocked"`, see "Gate
  state").

  Options: `:rules`, the IDs of the rules that ran (default: every rule).
  Previous findings of rules that did not run (turned `:off` in the
  configuration) are kept, so a narrower rule set never drops acknowledged
  entries. So are previous findings whose slice or module is not compared
  in `inventory` (now `unsupported`, `unavailable` or `unanalysed`), and
  previous `compared` inventory entries of modules that are now
  unavailable (see "Regeneration"). A kept entry written by another
  adapter (its own `"adapter"`, or the previous file's when it has none)
  is kept with its adapter and `"pending_reconciliation": true`: the
  running adapter never rechecked it, so it acknowledges nothing (see
  "Adapter compatibility per entry"). A kept entry whose own adapter is the
  running one loses a `"pending_reconciliation"` flag it had.
  """
  @spec build([Issue.t()], [map()], String.t(), t() | nil, keyword()) :: map()
  def build(issues, inventory, adapter, previous, opts \\ []) do
    rules = Keyword.get(opts, :rules)
    previous_entries = (previous && previous.findings) || []
    previous_findings = Map.new(previous_entries, &{&1["fingerprint"], &1})
    not_analysed = not_analysed(inventory)

    kept =
      for entry <- previous_entries,
          not ran?(entry["rule"], rules) or not_analysed?(entry, not_analysed),
          do: keep(entry, previous, adapter)

    findings =
      for %Issue{rule: rule} = issue <- issues, rule != "SL008" do
        old = Map.get(previous_findings, issue.fingerprint, %{})

        %{
          "rule" => issue.rule,
          "name" => Atom.to_string(issue.name),
          "mfa" => Issue.subject(issue),
          "slice" => issue.slice,
          "clause" => issue.clause,
          "evidence" => Atom.to_string(issue.evidence),
          "fingerprint" => issue.fingerprint,
          "adapter" => adapter,
          "blocked" => issue |> Issue.blocked() |> Enum.map(&Atom.to_string/1) |> Enum.sort(),
          "reason" => Map.get(old, "reason"),
          "owner" => Map.get(old, "owner"),
          "expires" => Map.get(old, "expires")
        }
      end
      |> Kernel.++(kept)
      |> Enum.uniq_by(& &1["fingerprint"])
      |> Enum.sort_by(&{&1["mfa"], &1["rule"], &1["slice"] || -1, &1["clause"] || -1})

    %{
      "version" => @version,
      "adapter" => adapter,
      "findings" => findings,
      "inventory" => build_inventory(inventory, previous, not_analysed)
    }
  end

  defp build_inventory(inventory, previous, {_not_compared, unavailable_modules}) do
    previous_inventory = (previous && previous.inventory) || []
    previous_acks = Map.new(previous_inventory, &{inventory_key(&1), &1})

    current =
      for entry <- inventory, do: carry_acknowledgement(stored_entry(entry), previous_acks)

    # The compared slices of a module that is now unavailable as a whole:
    # kept, so a spec removed while the module could not be read is still
    # seen once it can.
    keys = MapSet.new(current, &inventory_key/1)

    carried =
      for %{"status" => "compared", "mfa" => mfa} = entry <- previous_inventory,
          is_binary(mfa),
          MapSet.member?(unavailable_modules, entry["module"]),
          not MapSet.member?(keys, inventory_key(entry)),
          do: entry

    Enum.sort_by(current ++ carried, &inventory_sort_key/1)
  end

  defp carry_acknowledgement(%{"status" => "compared"} = stored, _previous_acks), do: stored

  defp carry_acknowledgement(stored, previous_acks) do
    old = Map.get(previous_acks, inventory_key(stored), %{})

    ack =
      if old["status"] == stored["status"],
        do: old["acknowledged"] || "initial baseline",
        else: "initial baseline"

    Map.put(stored, "acknowledged", ack)
  end

  # A previous finding kept by build/5: rechecked only when it is its own
  # adapter's (then any pending flag goes), pending otherwise.
  defp keep(entry, previous, adapter) do
    entry_adapter = entry_adapter(entry, previous)

    if entry_adapter == adapter,
      do: Map.delete(entry, "pending_reconciliation"),
      else: Map.merge(entry, %{"adapter" => entry_adapter, "pending_reconciliation" => true})
  end

  # The slices ({mfa, slice}) and modules a run did not compare, from the
  # current inventory (SpecLint.Coverage.entry/0): the analysis of their
  # findings did not happen.
  defp not_analysed(inventory) do
    not_compared =
      for %{mfa: mfa, slice: slice, status: status} <- inventory,
          mfa != nil and status != "compared",
          into: MapSet.new(),
          do: {mfa, slice}

    unavailable_modules =
      for %{mfa: nil, module: module} <- inventory, into: MapSet.new(), do: module

    {not_compared, unavailable_modules}
  end

  defp not_analysed?(entry, {not_compared, unavailable_modules}) do
    MapSet.member?(not_compared, {entry["mfa"], entry["slice"]}) or
      in_modules?(entry["mfa"], unavailable_modules)
  end

  # The adapter an entry was written by: its own, or the file's.
  defp entry_adapter(entry, baseline), do: entry["adapter"] || (baseline && baseline.adapter)

  defp pending?(entry), do: entry["pending_reconciliation"] == true

  # Whether an entry may acknowledge issues of the running adapter.
  defp compatible?(entry, baseline, adapter),
    do: entry_adapter(entry, baseline) == adapter and not pending?(entry)

  @doc "Writes a baseline map atomically as deterministic JSON."
  @spec write(Path.t(), map()) :: :ok | {:error, String.t()}
  def write(path, baseline), do: Json.write_atomic(path, Json.encode(baseline))

  ## Decisions

  @doc """
  Marks each issue `:baselined`, `:expired` or `:new` against `baseline`
  (`nil` when there is none) and lists stale entries.

  Options: `:adapter` (the current adapter ID; a baseline from another
  adapter is not applied), `:complete?` (stale entries are only listed for
  a complete, unfiltered run), `:today` (a `Date`, for `expires`),
  `:rules` (IDs of the rules that ran; baseline findings of other rules
  are never stale, and inventory acknowledgements are stale only when
  `"SL008"` is listed; default: every rule), `:inventory` (the current
  inventory, `SpecLint.Coverage.entry/0`: a finding whose slice or module
  is not compared now is never stale).

  A finding entry from another adapter, or marked
  `"pending_reconciliation"`, never acknowledges an issue and is never
  stale; it is listed in `pending_reconciliation`. An entry written with
  blocked prerequisites does not acknowledge the issue once it gates by
  its prerequisites; the issue stays new and the entry is listed in
  `gate_changed` (see "Gate state").
  """
  @spec decide([Issue.t()], t() | nil, keyword()) :: {[Issue.t()], decisions()}
  def decide(issues, nil, _opts), do: {issues, not_applied(:missing)}

  def decide(issues, %__MODULE__{} = baseline, opts) do
    adapter = Keyword.fetch!(opts, :adapter)

    if baseline.adapter != adapter do
      {issues, not_applied(:adapter_mismatch)}
    else
      apply_baseline(issues, baseline, opts)
    end
  end

  @doc "The decisions of a run no baseline was applied to, for `reason`."
  @spec not_applied(:missing | :adapter_mismatch) :: decisions()
  def not_applied(reason) do
    %{
      applied: false,
      reason: reason,
      stale_findings: [],
      stale_inventory: [],
      pending_reconciliation: [],
      gate_changed: []
    }
  end

  defp apply_baseline(issues, baseline, opts) do
    today = Keyword.get_lazy(opts, :today, &Date.utc_today/0)
    adapter = Keyword.fetch!(opts, :adapter)

    {usable, pending} =
      Enum.split_with(baseline.findings, &compatible?(&1, baseline, adapter))

    baseline = %{baseline | findings: usable}
    findings = Map.new(usable, &{&1["fingerprint"], &1})

    acks =
      for entry <- baseline.inventory,
          entry["status"] in @acknowledged_statuses,
          into: %{},
          do: {inventory_key(entry), entry}

    {issues, gate_changed} =
      Enum.map_reduce(issues, [], fn issue, changed ->
        case decide_issue(issue, acks, findings, today) do
          {:gate_changed, entry} -> {issue, [entry | changed]}
          decided -> {decided, changed}
        end
      end)

    {stale_findings, stale_inventory} =
      if Keyword.get(opts, :complete?, false) do
        stale(issues, baseline, opts)
      else
        {[], []}
      end

    {issues,
     %{
       applied: true,
       reason: nil,
       stale_findings: stale_findings,
       stale_inventory: stale_inventory,
       pending_reconciliation: pending,
       gate_changed: gate_changed |> Enum.uniq() |> Enum.sort_by(& &1["fingerprint"])
     }}
  end

  # The issue with its baseline decision, or {:gate_changed, entry} when
  # the matching entry was written report-only and the issue gates now.
  defp decide_issue(%Issue{rule: "SL008"} = issue, acks, _findings, _today) do
    case acknowledgement(acks, issue) do
      {:ok, entry} ->
        if entry["status"] == issue.data[:status],
          do: %{issue | baseline: :baselined},
          else: issue

      :error ->
        issue
    end
  end

  defp decide_issue(%Issue{} = issue, _acks, findings, today) do
    case Map.fetch(findings, issue.fingerprint) do
      {:ok, entry} ->
        if gate_changed?(entry, issue),
          do: {:gate_changed, entry},
          else: %{issue | baseline: expiry(entry, today)}

      :error ->
        issue
    end
  end

  # An entry written while a gating prerequisite was blocked (report-only)
  # does not acknowledge the issue once its prerequisites are met and it
  # gates. Entries without "blocked" predate the field.
  defp gate_changed?(%{"blocked" => [_ | _]}, issue),
    do: Policy.gated_by_prerequisites?(issue) and Issue.prerequisites_met?(issue)

  defp gate_changed?(_entry, _issue), do: false

  # An unsupported checker chunk is a preflight failure (DESIGN.md 5.1): no
  # inventory entry acknowledges it.
  defp acknowledgement(acks, %Issue{data: data} = issue) do
    case data do
      %{reason: "unsupported_chunk" <> _} -> :error
      _ -> Map.fetch(acks, {Issue.subject(issue), issue.slice})
    end
  end

  # An expires value that is not a date counts as expired: parse/2 rejects
  # it, so this only guards baselines built in memory.
  defp expiry(%{"expires" => expires}, today) when is_binary(expires) do
    case parse_date(expires) do
      {:ok, date} -> if Date.compare(today, date) == :gt, do: :expired, else: :baselined
      {:error, _} -> :expired
    end
  end

  defp expiry(%{"expires" => nil}, _today), do: :baselined
  defp expiry(%{"expires" => _other}, _today), do: :expired
  defp expiry(_entry, _today), do: :baselined

  defp stale(issues, baseline, opts) do
    rules = Keyword.get(opts, :rules)
    inventory = Keyword.get(opts, :inventory)
    fingerprints = MapSet.new(issues, & &1.fingerprint)
    not_analysed = not_analysed(inventory || [])

    stale_findings =
      Enum.reject(baseline.findings, fn entry ->
        MapSet.member?(fingerprints, entry["fingerprint"]) or not ran?(entry["rule"], rules) or
          not_analysed?(entry, not_analysed)
      end)

    stale_inventory =
      stale_inventory(issues, baseline, rules) ++
        stale_compared(baseline, inventory, rules, not_analysed)

    {stale_findings, stale_inventory}
  end

  defp stale_inventory(issues, baseline, rules) do
    if ran?("SL008", rules) do
      acknowledged =
        for %Issue{rule: "SL008", baseline: :baselined} = issue <- issues,
            into: MapSet.new(),
            do: {Issue.subject(issue), issue.slice}

      for entry <- baseline.inventory,
          entry["status"] in @acknowledged_statuses,
          not MapSet.member?(acknowledged, inventory_key(entry)),
          do: entry
    else
      []
    end
  end

  # Compared entries whose slice is in no current inventory entry, outside
  # the modules that are unavailable: the definition, its module or its
  # BEAM file is gone. Only with the current inventory.
  defp stale_compared(_baseline, nil, _rules, _not_analysed), do: []

  defp stale_compared(baseline, inventory, rules, {_not_compared, unavailable_modules}) do
    if ran?("SL008", rules) do
      present = MapSet.new(inventory, &{&1.mfa || &1.module, &1.slice})

      for %{"status" => "compared", "mfa" => mfa} = entry <- baseline.inventory,
          is_binary(mfa),
          not MapSet.member?(present, inventory_key(entry)),
          not MapSet.member?(unavailable_modules, entry["module"]),
          do: entry
    else
      []
    end
  end

  defp ran?(_rule, nil), do: true
  defp ran?(rule, rules), do: rule in rules

  # Whether a finding's subject (`Mod.fun/arity`, or a module) belongs to
  # one of `modules` (inspected module names). The module of an MFA string
  # is read from its Elixir alias segments; when the string has another
  # shape, any module that prefixes it counts, which errs towards not stale.
  defp in_modules?(subject, modules) when is_binary(subject) do
    MapSet.member?(modules, subject) or
      case module_of(subject) do
        nil -> Enum.any?(modules, &String.starts_with?(subject, &1 <> "."))
        module -> MapSet.member?(modules, module)
      end
  end

  defp in_modules?(_subject, _modules), do: false

  defp module_of(mfa) do
    alias_then_function = ~r/^((?:[A-Z][A-Za-z0-9_]*\.)*[A-Z][A-Za-z0-9_]*)\.[^A-Z].*\/\d+$/

    case Regex.run(alias_then_function, mfa) do
      [_, module] -> module
      nil -> nil
    end
  end

  @doc "The key of an inventory entry: its subject (MFA or module) and slice."
  @spec inventory_key(map()) :: {String.t() | nil, non_neg_integer() | nil}
  def inventory_key(entry), do: {entry["mfa"] || entry["module"], entry["slice"]}

  defp inventory_sort_key(entry), do: {entry["module"], entry["mfa"] || "", entry["slice"] || -1}

  defp stored_entry(entry) do
    %{
      "module" => entry.module,
      "mfa" => entry.mfa,
      "slice" => entry.slice,
      "status" => entry.status,
      "reason" => entry.reason,
      "translation" => entry.translation
    }
  end
end
