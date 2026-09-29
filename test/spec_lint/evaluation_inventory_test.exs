defmodule SpecLint.EvaluationInventoryTest do
  # The frozen evaluation inventory (bench/evaluation/inventory.json) against
  # its committed witness records and release measurements. The Milestone 5
  # review found witness references that did not resolve to any record
  # (version 1 cited holdout case ids its record did not contain) and a
  # release campaign without a committed detection measurement.
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @inventory Path.join(@root, "bench/evaluation/inventory.json")
  @detection Path.join(@root, "bench/evaluation/detection.exs")

  defp read_json!(path), do: path |> File.read!() |> JSON.decode!()

  defp inventory, do: read_json!(@inventory)

  test "every witness of a witnessed family resolves to exactly one in-domain observation outside the declared return" do
    for family <- inventory()["families"],
        family["status"] == "witnessed",
        witness <- family["witnesses"] do
      record = read_json!(Path.join(@root, witness["record"]))
      matches = Enum.filter(record["observations"], &(&1["case"] == witness["case"]))
      where = "#{family["id"]}: #{witness["case"]} in #{witness["record"]}"

      assert [observation] = matches, where
      assert observation["mfa"] == witness["mfa"], where
      assert witness["mfa"] in family["mfas"], where
      assert witness["input_in_declared_domain"] == true, where
      assert in_domain_and_outside?(observation), where

      if control = witness["control_case"] do
        assert [control] = Enum.filter(record["observations"], &(&1["case"] == control)), where
        assert control["input_in_declared_domain"] == true, where
        assert control["outside_declared_return"] == false, where
      end
    end
  end

  # The four record formats: pinned_witnesses.json (role, inside_declared_return),
  # expansion witnesses.json (output_in_declared_domain), the Ash integration
  # record (witness_input_in_declared_domain, verdict) and the holdout record
  # (input_in_declared_domain, outside_declared_return, verdict).
  defp in_domain_and_outside?(%{"verdict" => verdict} = observation)
       when is_map_key(observation, "witness_input_in_declared_domain"),
       do: verdict == "witnessed" and observation["witness_input_in_declared_domain"] == true

  defp in_domain_and_outside?(%{"verdict" => verdict} = observation),
    do:
      verdict == "witnessed" and observation["input_in_declared_domain"] == true and
        observation["outside_declared_return"] == true

  defp in_domain_and_outside?(%{"role" => role} = observation),
    do:
      role == "witness" and observation["input_in_declared_domain"] == true and
        observation["inside_declared_return"] == false

  defp in_domain_and_outside?(observation),
    do:
      observation["input_in_declared_domain"] == true and
        observation["output_in_declared_domain"] == false

  test "families, candidates and the denominator are consistent" do
    inventory = inventory()

    ids =
      Enum.map(inventory["families"], & &1["id"]) ++
        Enum.map(inventory["candidates_not_counted"], & &1["id"])

    assert ids == Enum.uniq(ids)

    witnessed = Enum.filter(inventory["families"], &(&1["status"] == "witnessed"))
    assert length(witnessed) == 18
    assert Enum.count(witnessed, &(&1["category"] == "return_value")) == 15

    mfas = Enum.flat_map(inventory["families"], & &1["mfas"])
    assert mfas == Enum.uniq(mfas), "an MFA belongs to two families"

    for family <- witnessed do
      assert Map.has_key?(inventory["corpora"], family["corpus"]), family["id"]

      assert family["revision"] == inventory["corpora"][family["corpus"]]["revision"],
             family["id"]
    end

    refute Enum.any?(inventory["candidates_not_counted"], &("Ash.Query.apply_to/3" in &1["mfas"]))
  end

  test "the committed release-1 detection is what detection.exs computes from the committed reports" do
    committed = read_json!(Path.join(@root, "bench/corpus/reports/release-1/detection_v2.json"))
    assert committed["inventory_version"] == inventory()["version"]
    args = for {name, set} <- Enum.sort(committed["sets"]), do: "#{name}=#{set["dir"]}"

    {output, 0} = System.cmd("elixir", [@detection | args], cd: @root)
    assert JSON.decode!(output) == committed

    for {_name, set} <- committed["sets"] do
      assert %{"gated" => 3, "reported" => 8, "silent" => 7, "denominator" => 18} = set["all"]

      assert %{"gated" => 2, "reported" => 8, "silent" => 5, "denominator" => 15} =
               set["return_value"]
    end
  end
end
