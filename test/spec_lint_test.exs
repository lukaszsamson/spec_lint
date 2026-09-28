defmodule SpecLintTest do
  use ExUnit.Case
  doctest SpecLint

  test "greets the world" do
    assert SpecLint.hello() == :world
  end
end
