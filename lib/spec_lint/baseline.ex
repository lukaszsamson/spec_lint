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
    * the spec slice AST with every annotation (line, column) removed;
    * the translated bounds of every argument and of the return, which is
      the spec after named-type expansion, through the adapter's canonical
      serialisation (`SpecLint.Compiler.canonical/1`), with their loss
      records;
    * the inferred clauses the finding rests on, canonically serialised;
    * a rule-specific extra term (for `SL008`, the status and reason).

  So a line change or reordering other functions keeps the fingerprint,
  while reordering the spec's clauses changes it (the slice index is part
  of the evidence). The hash is SHA-256 over
  `:erlang.term_to_binary(term, [:deterministic])`.

  ## Decisions

  `decide/3` marks every issue `:baselined`, `:expired` or `:new`, and lists
  stale entries. Findings are matched by fingerprint; `SL008` issues by an
  inventory entry with the same subject, slice and status. Stale entries
  are warnings, and a partial or incomplete run never declares an entry
  stale. A baseline written by another compiler adapter is not applied at
  all: reconciling it is a deliberate step (`mix spec_lint.baseline`).
  """

  alias SpecLint.{Bound, Compiler, Issue}
  alias SpecLint.Report.Json

  @version 1

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
          optional(:spec) => tuple() | nil,
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
          stale_inventory: [inventory_entry()]
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
      input |> Map.get(:spec) |> strip_annotations(),
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
    {Compiler.canonical(bound.lo), Compiler.canonical(bound.hi),
     Enum.map(bound.losses, &{&1.kind, &1.path}), bound.integers}
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
  AST depends only on the spec's structure.
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
  `{:error, message}` when it cannot be read or is not a version
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

  @doc "Parses baseline JSON contents."
  @spec parse(String.t(), Path.t() | nil) :: {:ok, t()} | {:error, String.t()}
  def parse(contents, path \\ nil) do
    case JSON.decode(contents) do
      {:ok, %{"version" => @version, "findings" => findings, "inventory" => inventory} = map}
      when is_list(findings) and is_list(inventory) ->
        if Enum.all?(findings, &valid_finding?/1) and Enum.all?(inventory, &is_map/1) do
          {:ok,
           %__MODULE__{
             path: path,
             adapter: Map.get(map, "adapter"),
             findings: findings,
             inventory: inventory
           }}
        else
          {:error, "invalid baseline #{path}: malformed finding or inventory entry"}
        end

      {:ok, %{"version" => version}} ->
        {:error, "unsupported baseline version #{inspect(version)} in #{path}"}

      {:ok, _other} ->
        {:error, "invalid baseline #{path}: expected version, findings and inventory"}

      {:error, reason} ->
        {:error, "invalid baseline JSON in #{path}: #{inspect(reason)}"}
    end
  end

  defp valid_finding?(%{"fingerprint" => "sha256:" <> _}), do: true
  defp valid_finding?(_finding), do: false

  @doc """
  Builds the baseline written by `mix spec_lint.baseline` from the current
  reported issues and inventory. Every non-`SL008` issue becomes a finding
  (whether it gates or not, since `--warnings-as-errors` can gate any);
  `SL008` issues are acknowledged through their inventory entries. The
  `reason`, `owner` and `expires` of a previous entry with the same
  fingerprint (or inventory key and status) are kept; new inventory
  acknowledgements get `"initial baseline"`, to be reviewed.
  """
  @spec build([Issue.t()], [map()], String.t(), t() | nil) :: map()
  def build(issues, inventory, adapter, previous) do
    previous_findings =
      Map.new((previous && previous.findings) || [], &{&1["fingerprint"], &1})

    previous_acks =
      Map.new((previous && previous.inventory) || [], &{inventory_key(&1), &1})

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
          "reason" => Map.get(old, "reason"),
          "owner" => Map.get(old, "owner"),
          "expires" => Map.get(old, "expires")
        }
      end
      |> Enum.uniq_by(& &1["fingerprint"])
      |> Enum.sort_by(&{&1["mfa"], &1["rule"], &1["slice"] || -1, &1["clause"] || -1})

    inventory =
      for entry <- inventory do
        stored = stored_entry(entry)

        if stored["status"] == "compared" do
          stored
        else
          old = Map.get(previous_acks, inventory_key(stored), %{})

          ack =
            if old["status"] == stored["status"],
              do: old["acknowledged"] || "initial baseline",
              else: "initial baseline"

          Map.put(stored, "acknowledged", ack)
        end
      end
      |> Enum.sort_by(&inventory_sort_key/1)

    %{
      "version" => @version,
      "adapter" => adapter,
      "findings" => findings,
      "inventory" => inventory
    }
  end

  @doc "Writes a baseline map atomically as deterministic JSON."
  @spec write(Path.t(), map()) :: :ok | {:error, String.t()}
  def write(path, baseline), do: Json.write_atomic(path, Json.encode(baseline))

  ## Decisions

  @doc """
  Marks each issue `:baselined`, `:expired` or `:new` against `baseline`
  (`nil` when there is none) and lists stale entries.

  Options: `:adapter` (the current adapter ID; a baseline from another
  adapter is not applied), `:complete?` (stale entries are only listed for
  a complete, unfiltered run), `:today` (a `Date`, for `expires`).
  """
  @spec decide([Issue.t()], t() | nil, keyword()) :: {[Issue.t()], decisions()}
  def decide(issues, nil, _opts) do
    {issues, %{applied: false, reason: :missing, stale_findings: [], stale_inventory: []}}
  end

  def decide(issues, %__MODULE__{} = baseline, opts) do
    adapter = Keyword.fetch!(opts, :adapter)

    if baseline.adapter != adapter do
      {issues,
       %{applied: false, reason: :adapter_mismatch, stale_findings: [], stale_inventory: []}}
    else
      apply_baseline(issues, baseline, opts)
    end
  end

  defp apply_baseline(issues, baseline, opts) do
    today = Keyword.get_lazy(opts, :today, &Date.utc_today/0)
    findings = Map.new(baseline.findings, &{&1["fingerprint"], &1})

    acks =
      for entry <- baseline.inventory,
          entry["status"] in ["unsupported", "unavailable"],
          into: %{},
          do: {inventory_key(entry), entry}

    issues =
      Enum.map(issues, fn
        %Issue{rule: "SL008"} = issue ->
          case Map.fetch(acks, {Issue.subject(issue), issue.slice}) do
            {:ok, entry} ->
              if entry["status"] == issue.data[:status],
                do: %{issue | baseline: :baselined},
                else: issue

            :error ->
              issue
          end

        %Issue{} = issue ->
          case Map.fetch(findings, issue.fingerprint) do
            {:ok, entry} -> %{issue | baseline: expiry(entry, today)}
            :error -> issue
          end
      end)

    {stale_findings, stale_inventory} =
      if Keyword.get(opts, :complete?, false) do
        stale(issues, baseline)
      else
        {[], []}
      end

    {issues,
     %{
       applied: true,
       reason: nil,
       stale_findings: stale_findings,
       stale_inventory: stale_inventory
     }}
  end

  defp expiry(%{"expires" => expires}, today) when is_binary(expires) do
    case Date.from_iso8601(expires) do
      {:ok, date} -> if Date.compare(today, date) == :gt, do: :expired, else: :baselined
      {:error, _} -> :baselined
    end
  end

  defp expiry(_entry, _today), do: :baselined

  defp stale(issues, baseline) do
    fingerprints = MapSet.new(issues, & &1.fingerprint)

    acknowledged =
      for %Issue{rule: "SL008", baseline: :baselined} = issue <- issues,
          into: MapSet.new(),
          do: {Issue.subject(issue), issue.slice}

    stale_findings =
      Enum.reject(baseline.findings, &MapSet.member?(fingerprints, &1["fingerprint"]))

    stale_inventory =
      for entry <- baseline.inventory,
          entry["status"] in ["unsupported", "unavailable"],
          not MapSet.member?(acknowledged, inventory_key(entry)),
          do: entry

    {stale_findings, stale_inventory}
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
