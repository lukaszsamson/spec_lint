defmodule SpecLint.Config do
  @moduledoc """
  Configuration from `.spec_lint.exs` and the command line (DESIGN.md
  section 8).

  ```elixir
  [
    analysis: :signatures,
    profile: :review,
    baseline: ".spec_lint_baseline.json",
    rules: [
      possible_missing_return: :warning,
      possible_missing_input: :off,
      return_can_be_narrower: :off
    ],
    coverage: [fail_on_regression: true, floor: 0],
    exclude: ["lib/generated/**"],
    expand_opaque: false,
    require_static_return: false,
    clause_local_qualification: true,
    warnings_as_errors: false
  ]
  ```

  The file must evaluate to a keyword list. Unknown keys, unknown rules and
  invalid values are rejected with an error, never ignored. Rules are keyed
  by name or ID (`:SL002`); a value is a severity (`:error`, `:warning`,
  `:info`, `:hint`) or `:off`. A severity changes how a finding is
  printed, never whether it gates. Command-line options override the file
  (`merge_cli/2`).

  `require_static_return` defaults to `false`, the Phase 1 rerun decision
  (DESIGN.md section 4, `EXPERIMENTS.md`).

  `clause_local_qualification` defaults to `true`, the Close-phase decision
  of 2026-09-29 (DESIGN.md section 4, `bench/corpus/clause_local_qualification.md`):
  an `SL001` `clause_conflict` needs its clause's whole domain contained in
  the spec's argument lower bounds instead of the slice-wide arrow
  prerequisites (`SpecLint.Rules.ReturnConflict`), in both profiles.
  `false` restores the slice-wide arrow prerequisites.

  A baseline path given explicitly (`baseline:` in the file, or
  `--baseline`) sets `baseline_explicit`: `SpecLint.Run` then treats a
  missing file as a configuration error, as `load/2` does for an explicit
  `--config`, so a mistyped path cannot silently disable the baseline and
  with it regression detection. The default path may be missing (a project
  without a baseline yet).
  """

  alias SpecLint.Rules

  @severities [:error, :warning, :info, :hint]

  @type profile :: :review | :soundness

  @type t :: %__MODULE__{
          analysis: :signatures | :bodies,
          profile: profile(),
          baseline: String.t(),
          rules: %{optional(String.t()) => SpecLint.Issue.severity() | :off},
          coverage: %{fail_on_regression: boolean(), floor: non_neg_integer()},
          exclude: [String.t()],
          expand_opaque: boolean(),
          require_static_return: boolean(),
          clause_local_qualification: boolean(),
          warnings_as_errors: boolean(),
          baseline_explicit: boolean(),
          source: String.t() | nil
        }

  defstruct analysis: :signatures,
            profile: :review,
            baseline: ".spec_lint_baseline.json",
            rules: %{},
            coverage: %{fail_on_regression: true, floor: 0},
            exclude: [],
            expand_opaque: false,
            require_static_return: false,
            clause_local_qualification: true,
            warnings_as_errors: false,
            baseline_explicit: false,
            source: nil

  @keys [
    :analysis,
    :profile,
    :baseline,
    :rules,
    :coverage,
    :exclude,
    :expand_opaque,
    :require_static_return,
    :clause_local_qualification,
    :warnings_as_errors
  ]

  @doc "The default file name, relative to the project root."
  @spec default_file() :: String.t()
  def default_file, do: ".spec_lint.exs"

  @doc """
  Loads the configuration file `file` under `root`. A missing file gives the
  defaults; an explicitly given `file` that does not exist is an error.
  """
  @spec load(Path.t(), Path.t() | nil) :: {:ok, t()} | {:error, String.t()}
  def load(root, file \\ nil) do
    path = Path.expand(file || default_file(), root)

    cond do
      File.regular?(path) -> eval(path)
      file == nil -> {:ok, %__MODULE__{}}
      true -> {:error, "configuration file not found: #{path}"}
    end
  end

  defp eval(path) do
    {value, _binding} = Code.eval_file(path)

    with {:ok, config} <- from_keyword(value) do
      {:ok, %{config | source: path}}
    end
  rescue
    error -> {:error, "cannot evaluate #{path}: #{Exception.message(error)}"}
  catch
    kind, reason ->
      {:error, "cannot evaluate #{path}: #{Exception.format_banner(kind, reason)}"}
  end

  @doc "Builds a configuration from a keyword list, validating every key."
  @spec from_keyword(term()) :: {:ok, t()} | {:error, String.t()}
  def from_keyword(value) do
    if is_list(value) and Keyword.keyword?(value) do
      reduce_ok(value, %__MODULE__{}, fn {key, val}, config -> put(config, key, val) end)
    else
      {:error, "configuration must be a keyword list, got: #{inspect(value)}"}
    end
  end

  defp put(config, :analysis, value) when value in [:signatures, :bodies],
    do: {:ok, %{config | analysis: value}}

  defp put(config, :profile, value) when value in [:review, :soundness],
    do: {:ok, %{config | profile: value}}

  defp put(config, :baseline, value) when is_binary(value),
    do: {:ok, %{config | baseline: value, baseline_explicit: true}}

  defp put(config, :rules, value), do: put_rules(config, value)
  defp put(config, :coverage, value), do: put_coverage(config, value)

  defp put(config, :exclude, value) when is_list(value) do
    if Enum.all?(value, &is_binary/1),
      do: {:ok, %{config | exclude: value}},
      else: invalid(:exclude, value)
  end

  defp put(config, key, value)
       when key in [
              :expand_opaque,
              :require_static_return,
              :clause_local_qualification,
              :warnings_as_errors
            ] and is_boolean(value),
       do: {:ok, Map.put(config, key, value)}

  defp put(_config, key, value) when key in @keys, do: invalid(key, value)

  defp put(_config, key, _value),
    do: {:error, "unknown configuration key #{inspect(key)}; known keys: #{inspect(@keys)}"}

  # Folds `fun` (returning `{:ok, config}` or an error tuple) over `enum`,
  # stopping at the first error.
  defp reduce_ok(enum, config, fun) do
    Enum.reduce_while(enum, {:ok, config}, fn item, {:ok, config} ->
      case fun.(item, config) do
        {:ok, config} -> {:cont, {:ok, config}}
        error -> {:halt, error}
      end
    end)
  end

  defp invalid(key, value), do: {:error, "invalid value for #{inspect(key)}: #{inspect(value)}"}

  defp put_rules(config, value) do
    if is_list(value) and Keyword.keyword?(value) do
      reduce_ok(value, config, fn {key, severity}, config -> put_rule(config, key, severity) end)
    else
      invalid(:rules, value)
    end
  end

  defp put_rule(config, key, severity) do
    with {:ok, rule} <- find_rule(key),
         :ok <- valid_severity(severity, key) do
      {:ok, %{config | rules: Map.put(config.rules, rule.id(), severity)}}
    end
  end

  defp valid_severity(severity, _key) when severity in [:off | @severities], do: :ok

  defp valid_severity(severity, key),
    do: {:error, "invalid severity #{inspect(severity)} for rule #{inspect(key)}"}

  defp find_rule(key) do
    case Rules.find(key) do
      {:ok, rule} -> {:ok, rule}
      :error -> {:error, "unknown rule #{inspect(key)}; known: #{Enum.join(Rules.ids(), ", ")}"}
    end
  end

  defp put_coverage(config, value) do
    if is_list(value) and Keyword.keyword?(value) do
      Enum.reduce_while(value, {:ok, config}, fn
        {:fail_on_regression, bool}, {:ok, config} when is_boolean(bool) ->
          {:cont, {:ok, %{config | coverage: %{config.coverage | fail_on_regression: bool}}}}

        {:floor, floor}, {:ok, config} when is_integer(floor) and floor >= 0 ->
          {:cont, {:ok, %{config | coverage: %{config.coverage | floor: floor}}}}

        {key, val}, _acc ->
          {:halt, {:error, "invalid coverage setting #{inspect(key)}: #{inspect(val)}"}}
      end)
    else
      invalid(:coverage, value)
    end
  end

  @doc """
  Applies command-line overrides: `:profile`, `:analysis`, `:baseline`,
  `:warnings_as_errors`, `:require_static_return`,
  `:clause_local_qualification` and `:exclude`.
  """
  @spec merge_cli(t(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def merge_cli(config, cli) do
    cli
    |> Keyword.take([
      :profile,
      :analysis,
      :baseline,
      :warnings_as_errors,
      :require_static_return,
      :clause_local_qualification,
      :exclude
    ])
    |> Enum.reject(fn {_key, value} -> value == nil end)
    |> reduce_ok(config, fn {key, value}, config -> put(config, key, value) end)
  end

  @doc """
  The enabled rules with their severities. `only` (from `--rules`)
  restricts the set and enables a listed rule that is off by default (at
  `:hint` severity when it has no configured one); `except` (from
  `--except`) removes rules. Both take rule IDs or names.
  """
  @spec enabled_rules(t(), [String.t()] | nil, [String.t()]) ::
          {:ok, [{module(), SpecLint.Issue.severity()}]} | {:error, String.t()}
  def enabled_rules(config, only, except) do
    with {:ok, only} <- resolve(only),
         {:ok, except} <- resolve(except || []) do
      rules =
        for rule <- Rules.all(),
            only == nil or rule in only,
            rule not in except,
            severity = severity(config, rule, only != nil),
            severity != :off,
            do: {rule, severity}

      {:ok, rules}
    end
  end

  defp resolve(nil), do: {:ok, nil}

  defp resolve(keys) do
    Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, acc} ->
      case find_rule(key) do
        {:ok, rule} -> {:cont, {:ok, acc ++ [rule]}}
        error -> {:halt, error}
      end
    end)
  end

  defp severity(config, rule, explicit?) do
    case Map.get(config.rules, rule.id(), rule.default_severity()) do
      :off when explicit? -> :hint
      severity -> severity
    end
  end

  @doc """
  A digest of the effective configuration (without its source path and
  without whether the baseline path was explicit), for the report
  envelope.
  """
  @spec digest(t()) :: String.t()
  def digest(config) do
    term =
      config |> Map.from_struct() |> Map.drop([:source, :baseline_explicit]) |> Enum.sort()

    hash = :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))
    "sha256:" <> Base.encode16(hash, case: :lower)
  end
end
