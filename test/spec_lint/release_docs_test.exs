defmodule SpecLint.ReleaseDocsTest do
  # The user-facing release documents (Milestone 5 review: the README was
  # committed with unfilled `{{...}}` placeholders, and a package meant for
  # the Elixir maintainers named a session-specific scratch path).
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  @documents [
    "README.md",
    "RELEASE.md" | Path.wildcard(Path.join(@root, "bench/upstream/**/*.md"))
  ]

  defp read!(path), do: path |> Path.expand(@root) |> File.read!()

  test "the release documents have no unfilled placeholders" do
    for path <- ["README.md", "RELEASE.md"] do
      text = read!(path)
      refute text =~ "{{", "#{path} has an unfilled {{...}} placeholder"
      refute text =~ "PLACEHOLDER", path
    end
  end

  test "the release documents name no local home or session paths" do
    for path <- @documents do
      text = read!(path)

      for pattern <- ["/private/tmp/", "claude-501", "/Users/"],
          do: refute(text =~ pattern, "#{Path.relative_to(path, @root)} contains #{pattern}")
    end
  end

  test "the README's release figures are those of the committed release reports" do
    readme = read!("README.md")

    for {adapter, dir} <- [{"c24c235", "c24c235"}, {"648b2a9", "648b2a9"}, {"1.20.4", "1.20.4"}] do
      reports =
        Path.wildcard(Path.join(@root, "bench/corpus/reports/release-1/#{dir}/*.spec_lint.json"))

      assert length(reports) == 15

      totals =
        reports
        |> Enum.map(&(&1 |> File.read!() |> JSON.decode!()))
        |> Enum.reduce(%{compared: 0, unknown: 0, gates: 0}, fn report, acc ->
          %{
            compared: acc.compared + report["ledger"]["slices"]["compared"],
            unknown: acc.unknown + Map.get(report["ledger"]["obligations"], "unknown", 0),
            gates: acc.gates + Enum.count(report["findings"], & &1["gate"])
          }
        end)

      row = Enum.find(String.split(readme, "\n"), &String.contains?(&1, "| #{label(adapter)} |"))
      assert row, "no README ledger row for #{adapter}"
      assert row =~ "| #{delimit(totals.compared)} |"
      assert row =~ "| **#{delimit(totals.unknown)}** |"
      assert totals.gates == 9
    end
  end

  defp label("1.20.4"), do: "1.20.4"
  defp label(revision), do: "1.21 `#{revision}`"

  defp delimit(n) when n >= 1000,
    do: "#{div(n, 1000)},#{n |> rem(1000) |> Integer.to_string() |> String.pad_leading(3, "0")}"

  defp delimit(n), do: Integer.to_string(n)
end
