# Detection of the frozen evaluation inventory in committed product reports.
#
#   elixir bench/evaluation/detection.exs NAME=REPORT_DIR [NAME=REPORT_DIR ...]
#
# Reads bench/evaluation/inventory.json and, for each named report set, the
# REPORT_DIR/CORPUS.spec_lint.json of every corpus with a witnessed family.
# A family is "gated" when one of its MFAs has an SL001 finding with gate
# true, "reported" when not gated but one of its MFAs has any finding, and
# "silent" otherwise (INVENTORY.md, "Counting"). Prints JSON with the report
# hashes, the class of every family and the recall figures.
#
# Each report must be complete, and its sibling REPORT_DIR/CORPUS.provenance.json
# must record the source revision the inventory pins for that corpus
# (`corpora[*].revision`): a report built from another revision of the
# library is not a measurement of the frozen inventory, and the script
# raises. Every counted finding is listed per family (`matched`: subject,
# rule, evidence, gate, slice, clause, fingerprint and the "inferred extra"
# or "stored signature clause" detail), so a reviewer can check that each
# match is the witnessed omission and not an unrelated finding on the same
# MFA (INVENTORY.md, "Counting", counts by subject MFA).

root = Path.expand("../..", __DIR__)
inventory = root |> Path.join("bench/evaluation/inventory.json") |> File.read!() |> JSON.decode!()
families = Enum.filter(inventory["families"], &(&1["status"] == "witnessed"))

sets =
  for arg <- System.argv() do
    case String.split(arg, "=", parts: 2) do
      [name, dir] -> {name, dir}
      _ -> raise "expected NAME=REPORT_DIR, got #{arg}"
    end
  end

if sets == [], do: raise("usage: elixir detection.exs NAME=REPORT_DIR ...")

sha256 = fn path ->
  "sha256:" <> Base.encode16(:crypto.hash(:sha256, File.read!(path)), case: :lower)
end

pinned_revision = fn report_corpus ->
  Enum.find_value(inventory["corpora"], fn {_name, corpus} ->
    if corpus["report"] == report_corpus, do: corpus["revision"]
  end)
end

measure = fn dir ->
  corpora = families |> Enum.map(&inventory["corpora"][&1["corpus"]]["report"]) |> Enum.uniq()

  reports =
    Map.new(corpora, fn corpus ->
      path = Path.join(dir, corpus <> ".spec_lint.json")
      report = path |> File.read!() |> JSON.decode!()

      unless report["completion"]["status"] == "complete",
        do: raise("#{path}: report is not complete")

      provenance = Path.join(dir, corpus <> ".provenance.json")
      revision = provenance |> File.read!() |> JSON.decode!() |> get_in(["source", "revision"])

      unless revision == pinned_revision.(corpus),
        do:
          raise(
            "#{provenance}: source revision #{inspect(revision)} is not the inventory pin " <>
              inspect(pinned_revision.(corpus))
          )

      {corpus,
       %{
         path: Path.relative_to(path, root),
         sha256: sha256.(path),
         revision: revision,
         report: report
       }}
    end)

  classes =
    for family <- families do
      corpus = inventory["corpora"][family["corpus"]]["report"]

      findings =
        Enum.filter(reports[corpus].report["findings"], &(&1["subject"] in family["mfas"]))

      class =
        cond do
          Enum.any?(findings, &(&1["rule"] == "SL001" and &1["gate"] == true)) -> "gated"
          findings != [] -> "reported"
          true -> "silent"
        end

      evidence =
        findings
        |> Enum.map(&"#{&1["subject"]} #{&1["rule"]} #{&1["evidence"]} gate=#{&1["gate"]}")
        |> Enum.frequencies()
        |> Enum.map(fn {text, n} -> if n == 1, do: text, else: "#{text} x#{n}" end)
        |> Enum.sort()

      matched =
        for finding <- findings do
          extra =
            for [label, text] <- finding["details"],
                label in ["inferred extra", "stored signature clause"],
                do: label <> ": " <> text

          finding
          |> Map.take(~w(subject rule evidence gate slice clause fingerprint))
          |> Map.put("extra", extra)
        end

      %{
        id: family["id"],
        category: family["category"],
        class: class,
        findings: evidence,
        matched: Enum.sort_by(matched, &{&1["subject"], &1["slice"], &1["clause"], &1["rule"]})
      }
    end

  tally = fn rows ->
    counts = Enum.frequencies_by(rows, & &1.class)
    gated = Map.get(counts, "gated", 0)
    reported = Map.get(counts, "reported", 0)
    silent = Map.get(counts, "silent", 0)

    %{
      denominator: length(rows),
      gated: gated,
      reported: reported,
      silent: silent,
      gated_recall: "#{gated}/#{length(rows)}",
      reported_recall: "#{gated + reported}/#{length(rows)}"
    }
  end

  %{
    reports:
      reports
      |> Enum.sort()
      |> Enum.map(fn {corpus, r} ->
        %{corpus: corpus, path: r.path, sha256: r.sha256, revision: r.revision}
      end),
    families: classes,
    all: tally.(classes),
    return_value: tally.(Enum.filter(classes, &(&1.category == "return_value"))),
    by_category:
      classes
      |> Enum.group_by(& &1.category)
      |> Map.new(fn {category, rows} -> {category, tally.(rows)} end)
  }
end

IO.puts(
  JSON.encode!(%{
    schema: "spec_lint/evaluation_detection",
    inventory_version: inventory["version"],
    sets: Map.new(sets, fn {name, dir} -> {name, Map.put(measure.(dir), :dir, dir)} end)
  })
)
