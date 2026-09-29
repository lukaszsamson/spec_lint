# Tags the findings of product reports whose extra return is a struct whose
# only violation is a default-nil field (NEXT_STEPS.md, Milestone 5: "count
# struct-default violations separately without changing their policy").
# Nothing here changes a finding, a gate or a report; the output is a
# separate count.
#
#     MIX_ENV=test mix run bench/evaluation/struct_defaults.exs -- \
#       --out OUT.json [--path-var NAME=DIR ...] REPORT_DIR
#
# REPORT_DIR holds the product reports (NAME.spec_lint.json) and their
# provenance (NAME.provenance.json) of one replay under the running
# compiler's adapter. The artifact directories of each provenance file
# (the corpus ebins, then its code paths) are the BEAM files the report was
# made from; their placeholders ($OSS, $BUILD, $ELIXIR) are replaced by the
# --path-var values (a placeholder given several times takes the first
# value whose directory exists). Every module a finding names is re-analysed from the
# first artifact directory that has its BEAM file, with the same analysis
# the product ran (SpecLint.Analysis.module/2 under the running adapter).
#
# Definition. For a finding on slice s of F and the spec return upper bound
# S_hi of s, the returns considered are the stored returns R_k of the clause
# the finding names (SL001 clause_conflict), or of every contributing clause
# of the slice (other findings), without clauses whose return's upper bound
# is term() (they carry no evidence, DESIGN.md 3.1 step 7). Every component
# (SpecLint.Compiler.components/1) of upper_bound(R_k) that is not a subtype
# of S_hi is a violation. A violation is a *struct default* when it is a
# closed struct literal %M{...} with at least one field that is exactly nil,
# whose default in M.__struct__/0 is nil and whose declared type excludes
# nil, and replacing the type of every such nil field with the type
# S_hi declares for that field of M (the union over S_hi's struct literals
# of M), gives a subtype of S_hi (criterion "subtype"), or, for a struct
# disjoint from S_hi, a type that is no longer disjoint from it (criterion
# "overlap": the nil fields are what puts it outside the spec, and its other
# fields are at most imprecise, such as an inferred term() where the spec
# declares a list). The finding is tagged `struct_default`
# when it has at least one violation and every violation is a struct
# default. Fields nested inside tuples, lists or other maps are not
# inspected: the tag is about a returned struct.
defmodule SpecLint.StructDefaults do
  @moduledoc false

  alias SpecLint.{Analysis, Compiler, TypeCache}

  @spec main([String.t()]) :: :ok
  def main(argv) do
    {opts, [dir], []} =
      OptionParser.parse(Enum.reject(argv, &(&1 == "--")),
        strict: [out: :string, path_var: :keep]
      )

    vars =
      opts
      |> Keyword.get_values(:path_var)
      |> Enum.map(fn value ->
        [name, path] = String.split(value, "=", parts: 2)
        {"$" <> name, path}
      end)

    {:ok, capabilities} = Compiler.preflight_once()

    corpora =
      for {corpus, json} <- complete_reports!(dir), json["findings"] != [] do
        {corpus, corpus_rows(corpus, json, Path.join(dir, corpus <> ".provenance.json"), vars)}
      end

    rows = Enum.flat_map(corpora, fn {_corpus, rows} -> rows end)

    out = %{
      "schema" => "spec_lint.struct_defaults/1",
      "adapter" => capabilities.adapter_id,
      "reports" => Path.expand(dir),
      "definition" =>
        "every violating component of the returns the finding rests on is a closed struct " <>
          "literal with fields that are exactly nil with a nil default; with those fields at " <>
          "the types the spec declares, it is inside the spec (subtype) or, being disjoint " <>
          "from the spec, no longer disjoint (overlap)",
      "findings" => rows,
      "totals" => totals(rows),
      "per_corpus" =>
        Map.new(corpora, fn {corpus, corpus_rows} -> {corpus, totals(corpus_rows)} end)
    }

    File.write!(opts[:out], JSON.encode_to_iodata!(out))
    IO.puts(:stderr, "struct defaults: #{inspect(out["totals"])} -> #{opts[:out]}")
  end

  # The corpora of REPORT_DIR are those with a product report or a
  # provenance file (not `fixtures`, which has no product report). A report
  # that is missing, unreadable or not complete is an error (exit 2), never
  # a corpus left out of the totals; so is a directory with no corpus.
  defp complete_reports!(dir) do
    corpora =
      ["*.spec_lint.json", "*.provenance.json"]
      |> Enum.flat_map(&Path.wildcard(Path.join(dir, &1)))
      |> Enum.map(&(&1 |> Path.basename() |> String.split(".") |> hd()))
      |> Enum.reject(&(&1 == "fixtures"))
      |> Enum.uniq()
      |> Enum.sort()

    if corpora == [], do: fail!("no product reports or provenance files in #{dir}")

    for corpus <- corpora do
      path = Path.join(dir, corpus <> ".spec_lint.json")

      json =
        with {:ok, text} <- File.read(path),
             {:ok, %{"completion" => %{"status" => "complete"}, "findings" => findings} = json}
             when is_list(findings) <- JSON.decode(text) do
          json
        else
          _ -> fail!("missing, unreadable or incomplete product report: #{path}")
        end

      {corpus, json}
    end
  end

  defp fail!(message) do
    IO.puts(:stderr, "struct_defaults: " <> message)
    System.halt(2)
  end

  defp totals(rows) do
    tagged = Enum.filter(rows, & &1["struct_default"])

    %{
      "findings" => length(rows),
      "struct_default" => length(tagged),
      "struct_default_gates" => Enum.count(tagged, & &1["gate"]),
      "gates" => Enum.count(rows, & &1["gate"]),
      "struct_default_subjects" => tagged |> Enum.map(& &1["subject"]) |> Enum.uniq()
    }
  end

  defp corpus_rows(corpus, report, provenance, vars) do
    dirs =
      provenance
      |> File.read!()
      |> JSON.decode!()
      |> Map.fetch!("artifacts")
      |> Enum.map(&expand(&1["path"], vars))
      |> Enum.uniq()

    Enum.each(Enum.reverse(dirs), &Code.prepend_path/1)
    cache = TypeCache.new()

    analyses =
      report["findings"]
      |> Enum.map(& &1["module"])
      |> Enum.uniq()
      |> Map.new(fn module -> {module, analyse(module, dirs, cache)} end)

    for finding <- report["findings"] do
      verdict = verdict(finding, Map.fetch!(analyses, finding["module"]))

      %{
        "corpus" => corpus,
        "subject" => finding["subject"],
        "rule" => finding["rule"],
        "evidence" => finding["evidence"],
        "slice" => finding["slice"],
        "clause" => finding["clause"],
        "gate" => finding["gate"],
        "fingerprint" => finding["fingerprint"],
        "struct_default" => verdict.struct_default,
        "violations" => verdict.violations
      }
    end
  end

  # A placeholder may be given several times (the original and the
  # expansion checkouts are both $OSS): the first expansion that exists.
  defp expand(path, vars) do
    candidates =
      Enum.reduce(vars |> Enum.map(&elem(&1, 0)) |> Enum.uniq(), [path], fn var, paths ->
        values = for {^var, value} <- vars, do: value
        for path <- paths, value <- values, do: String.replace(path, var, value)
      end)

    Enum.find(candidates, &File.dir?/1) || raise "no directory for #{path}"
  end

  defp analyse(module, dirs, cache) do
    file = "Elixir." <> module <> ".beam"

    case Enum.find(dirs, &File.regular?(Path.join(&1, file))) do
      nil -> raise "no BEAM file for #{module} in #{inspect(dirs)}"
      dir -> Analysis.module(Path.join(dir, file), cache: cache)
    end
  end

  defp verdict(finding, analysis) do
    [name, arity] = finding["subject"] |> String.split(".") |> List.last() |> split_na()
    module = Module.concat([finding["module"]])
    mfa = {module, String.to_atom(name), arity}

    function =
      Enum.find(analysis.functions, &(&1.mfa == mfa)) ||
        raise "#{finding["subject"]} not analysed"

    slice = Enum.find(function.slices, &(&1.index == finding["slice"]))
    relations = slice.relations
    spec = Compiler.upper_bound(relations.spec_return)

    clauses =
      if finding["evidence"] == "clause_conflict",
        do: Enum.filter(relations.contributing, &(&1.index == finding["clause"])),
        else: relations.contributing

    violations =
      for clause <- clauses,
          upper = Compiler.upper_bound(clause.return),
          not Compiler.subtype?(Compiler.term(), upper),
          component <- Compiler.components(upper),
          not Compiler.subtype?(component.descr, spec) do
        classify(component, spec)
      end

    %{
      struct_default:
        violations != [] and Enum.all?(violations, &(&1["kind"] == "struct_default")),
      violations: violations
    }
  end

  # "name/arity" of a subject; operators such as `!/1` have no dot issue
  # because subjects are Module.fun/arity with the function last.
  defp split_na(last) do
    [name, arity] = String.split(last, "/")
    [name, String.to_integer(arity)]
  end

  defp classify(%{view: {:map, :closed, fields, []}} = component, spec) do
    with {:ok, struct} <- struct_module(fields),
         {:ok, defaults} <- defaults(struct),
         nil_fields = nil_fields(fields, defaults),
         declared = declared(nil_fields, struct, spec),
         outside = Enum.reject(nil_fields, &Compiler.subtype?(Compiler.atom([nil]), declared[&1])),
         true <- outside != [],
         relaxed = Compiler.closed_map(relax(fields, declared), []),
         {:ok, criterion} <- criterion(component.descr, relaxed, spec) do
      %{
        "kind" => "struct_default",
        "criterion" => criterion,
        "struct" => inspect(struct),
        "fields" => Enum.map(outside, &Atom.to_string/1)
      }
    else
      _ -> other(component)
    end
  end

  defp classify(component, _spec), do: other(component)

  # "subtype": with the nil fields at their declared types the struct is
  # inside S_hi, so they are the whole violation. "overlap": the struct is
  # disjoint from S_hi and is not once they are, so they are what puts it
  # outside; its other fields are at most imprecise (an inferred term()).
  defp criterion(descr, relaxed, spec) do
    cond do
      Compiler.subtype?(relaxed, spec) ->
        {:ok, "subtype"}

      Compiler.disjoint?(descr, spec) and not Compiler.disjoint?(relaxed, spec) ->
        {:ok, "overlap"}

      true ->
        :error
    end
  end

  defp other(component), do: %{"kind" => "other", "component" => Atom.to_string(component.kind)}

  defp struct_module(fields) do
    with {:__struct__, type, false} <- List.keyfind(fields, :__struct__, 0),
         {:finite, [struct]} <- Compiler.atom_fetch(type) do
      {:ok, struct}
    else
      _ -> :error
    end
  end

  defp defaults(struct) do
    if Code.ensure_loaded?(struct) and function_exported?(struct, :__struct__, 0),
      do: {:ok, struct.__struct__()},
      else: :error
  end

  defp nil_fields(fields, defaults) do
    nil_type = Compiler.atom([nil])

    for {key, type, false} <- fields,
        key != :__struct__,
        Map.has_key?(defaults, key) and Map.fetch!(defaults, key) == nil,
        Compiler.equal?(type, nil_type),
        do: key
  end

  # The types S_hi declares for the fields `keys` of struct `struct`: the
  # union over its literals of that struct. A field S_hi never declares
  # (no literal of the struct) keeps nil, so it stays a violation.
  defp declared(keys, struct, spec) do
    found =
      for %{view: {:map, _, spec_fields, _}} <- Compiler.components(spec),
          {:ok, ^struct} <- [struct_module(spec_fields)],
          {key, type, _optional} <- spec_fields,
          key in keys,
          reduce: %{} do
        acc -> Map.update(acc, key, type, &Compiler.union(&1, type))
      end

    Map.new(keys, &{&1, Map.get(found, &1, Compiler.atom([nil]))})
  end

  defp relax(fields, declared) do
    Enum.map(fields, fn {key, type, optional} -> {key, Map.get(declared, key, type), optional} end)
  end
end

SpecLint.StructDefaults.main(System.argv())
