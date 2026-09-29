defmodule SpecLint.Report.Json do
  @moduledoc """
  The JSON report (DESIGN.md section 9): a versioned envelope, independent
  of compiler structures, with tool, adapter, Elixir, OTP and checker
  versions, BEAM hashes, the config digest, scope, capabilities, findings,
  the coverage ledger, baseline decisions and completion status.

  Output is deterministic: object keys are sorted, lists are sorted by the
  producer, nothing time- or machine-dependent is included (paths are
  relative to the project root, runtime is not recorded), so two runs on
  the same inputs are byte identical. Files are written atomically.
  """

  alias SpecLint.{Issue, Run}

  @schema "spec_lint/report"
  @schema_version 1

  @typedoc "A JSON-encodable term (atoms other than booleans and `nil` become strings)."
  @type json ::
          nil
          | boolean()
          | atom()
          | String.t()
          | number()
          | [json()]
          | %{optional(atom() | String.t()) => json()}

  @doc "The envelope schema version."
  @spec schema_version() :: 1
  def schema_version, do: @schema_version

  @doc "Builds the report envelope for a finished run."
  @spec envelope(Run.t()) :: map()
  def envelope(%Run{} = run) do
    caps = run.capabilities || %{}

    %{
      "schema" => @schema,
      "schema_version" => @schema_version,
      "tool" => %{"name" => "spec_lint", "version" => Run.tool_version()},
      "adapter" => caps[:adapter_id] && to_string(caps[:adapter_id]),
      "elixir" => System.version(),
      "otp" => System.otp_release(),
      "checker_version" => caps[:checker_version] && Atom.to_string(caps[:checker_version]),
      "project" => project(run),
      "config" => %{
        "digest" => run.config_digest,
        "profile" => Atom.to_string(run.config.profile),
        "expand_opaque" => run.config.expand_opaque,
        "require_static_return" => run.config.require_static_return,
        "clause_local_qualification" => run.config.clause_local_qualification,
        "warnings_as_errors" => run.config.warnings_as_errors,
        "ci" => run.ci?,
        "rules" =>
          Enum.map(run.rules, fn {rule, severity} -> [rule.id(), severity_string(severity)] end)
      },
      "scope" => %{
        "partial" => run.partial?,
        "apps" => Enum.map(run.project.apps, &Atom.to_string(&1.app)),
        "module_filters" => Enum.map(run.filters.modules, &inspect/1),
        "app_filters" => Enum.map(run.filters.apps, &Atom.to_string/1),
        "exclude" => run.config.exclude
      },
      "capabilities" => %{
        "signatures" => Map.get(caps, :signatures, false),
        "bodies" => false,
        "body_hook" => Map.get(caps, :body_hook, false)
      },
      "beams" =>
        for {module, path, md5} <- run.beams do
          %{"module" => module, "path" => path, "md5" => md5}
        end,
      "findings" => Enum.map(run.issues, &finding/1),
      "ledger" => run.ledger,
      "baseline" => baseline(run),
      "completion" => %{
        "status" => Atom.to_string(run.completion),
        "reasons" => run.completion_reasons,
        "exit_code" => run.exit_code,
        "blocking" => Enum.count(run.issues, &Issue.blocking?/1),
        "coverage_violations" => run.coverage_violations
      }
    }
  end

  defp project(run) do
    %{
      "umbrella" => run.project.umbrella?,
      "mix_env" => run.project.mix_env,
      "mix_target" => run.project.mix_target
    }
  end

  defp baseline(run) do
    decisions = run.baseline_decisions

    %{
      "path" => run.baseline_path,
      "applied" => decisions.applied,
      "reason" => decisions.reason && Atom.to_string(decisions.reason),
      "baselined" => Enum.count(run.issues, &(&1.baseline == :baselined)),
      "expired" => Enum.count(run.issues, &(&1.baseline == :expired)),
      "new" => Enum.count(run.issues, &(&1.baseline == :new)),
      "stale_findings" => decisions.stale_findings,
      "stale_inventory" => decisions.stale_inventory,
      "pending_reconciliation" => decisions.pending_reconciliation,
      "gate_changed" => decisions.gate_changed
    }
  end

  @doc "One finding as a JSON object."
  @spec finding(Issue.t()) :: map()
  def finding(%Issue{} = issue) do
    %{
      "rule" => issue.rule,
      "name" => Atom.to_string(issue.name),
      "subject" => Issue.subject(issue),
      "module" => inspect(issue.module),
      "slice" => issue.slice,
      "clause" => issue.clause,
      "evidence" => Atom.to_string(issue.evidence),
      "severity" => Atom.to_string(issue.severity),
      "file" => issue.file,
      "line" => issue.line,
      "message" => issue.message,
      "details" =>
        Enum.map(Issue.rendered_details(issue), fn {label, value} -> [label, value] end),
      "prerequisites" =>
        Enum.map(issue.prerequisites, fn {name, state} ->
          [Atom.to_string(name), Atom.to_string(state)]
        end),
      "data" => issue.data,
      "fingerprint" => issue.fingerprint,
      "gate" => issue.gate,
      "baseline" => Atom.to_string(issue.baseline),
      "blocking" => Issue.blocking?(issue)
    }
  end

  defp severity_string(severity), do: Atom.to_string(severity)

  ## Encoding

  @doc """
  Encodes a term as deterministic, indented JSON: map keys sorted, atoms
  as strings, `nil` as `null`. Tuples are not accepted.
  """
  @spec encode(json()) :: iolist()
  def encode(term), do: [do_encode(term, 0), "\n"]

  defp do_encode(map, _indent) when is_map(map) and map_size(map) == 0, do: "{}"

  defp do_encode(map, indent) when is_map(map) do
    pad = String.duplicate("  ", indent + 1)

    pairs =
      map
      |> Enum.map(fn {key, value} -> {to_string(key), value} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, value} ->
        [pad, JSON.encode!(key), ": ", do_encode(value, indent + 1)]
      end)
      |> Enum.intersperse(",\n")

    ["{\n", pairs, "\n", String.duplicate("  ", indent), "}"]
  end

  defp do_encode([], _indent), do: "[]"

  defp do_encode(list, indent) when is_list(list) do
    if Enum.all?(list, &scalar?/1) and length(list) <= 8 do
      ["[", list |> Enum.map(&do_encode(&1, indent)) |> Enum.intersperse(", "), "]"]
    else
      pad = String.duplicate("  ", indent + 1)
      items = list |> Enum.map(&[pad, do_encode(&1, indent + 1)]) |> Enum.intersperse(",\n")
      ["[\n", items, "\n", String.duplicate("  ", indent), "]"]
    end
  end

  defp do_encode(nil, _indent), do: "null"
  defp do_encode(true, _indent), do: "true"
  defp do_encode(false, _indent), do: "false"
  defp do_encode(value, _indent) when is_atom(value), do: JSON.encode!(Atom.to_string(value))
  defp do_encode(value, _indent) when is_binary(value), do: JSON.encode!(value)
  defp do_encode(value, _indent) when is_number(value), do: JSON.encode!(value)

  defp scalar?(value), do: is_binary(value) or is_number(value) or is_atom(value)

  @doc """
  Writes `iodata` to `path` atomically: to a temporary file in the same
  directory, then renamed over `path`. Creates the directory.
  """
  @spec write_atomic(Path.t(), iodata()) :: :ok | {:error, String.t()}
  def write_atomic(path, iodata) do
    path = Path.expand(path)
    tmp = path <> ".tmp-" <> Integer.to_string(:erlang.unique_integer([:positive]))

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, iodata),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, "cannot write #{path}: #{:file.format_error(reason)}"}
    end
  end
end
