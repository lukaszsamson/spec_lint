Code.require_file("../../bench/body_metrics.exs", __DIR__)

defmodule SpecLint.BodyMetricsTest do
  use ExUnit.Case, async: true

  alias SpecLint.BodyMetrics

  test "missing body analysis is unavailable, not a negative" do
    slices = [%{body: nil}, %{body: %{gate: false}}]

    assert BodyMetrics.flag(slices, :body, :gate) == nil
    assert BodyMetrics.outcome(true, BodyMetrics.flag(slices, :body, :gate)) == "unavailable"
    assert BodyMetrics.outcome(false, BodyMetrics.flag(slices, :body, :gate)) == "unavailable"
  end

  test "an observed finding survives a missing sibling slice" do
    slices = [%{body: nil}, %{body: %{gate: true}}]

    assert BodyMetrics.flag(slices, :body, :gate)
    assert BodyMetrics.outcome(true, BodyMetrics.flag(slices, :body, :gate)) == "detected"
  end

  test "complete negative analysis remains a negative" do
    slices = [%{body: %{gate: false}}, %{body: %{gate: false}}]

    refute BodyMetrics.flag(slices, :body, :gate)
    assert BodyMetrics.outcome(true, BodyMetrics.flag(slices, :body, :gate)) == "suppressed"
  end
end
