defmodule SpecLint.IsolatedTest do
  use ExUnit.Case, async: true

  alias SpecLint.Isolated

  # The crashes below are logged by the runtime; the log is not the subject.
  @moduletag :capture_log

  test "returns the function's value" do
    assert {:ok, {:done, pid}} = Isolated.run(fn -> {:done, self()} end)
    refute pid == self()
  end

  test "a crash comes back as a value, and the caller is not linked to it" do
    assert {:error, {:crashed, {%RuntimeError{message: "boom"}, [_ | _]}}} =
             Isolated.run(fn -> raise "boom" end)

    assert {:error, {:crashed, :stop}} = Isolated.run(fn -> exit(:stop) end)
    assert {:error, {:crashed, {{:nocatch, :ball}, _}}} = Isolated.run(fn -> throw(:ball) end)

    assert {:error, {:crashed, :killed}} =
             Isolated.run(fn -> Process.exit(self(), :kill) end)

    refute_received {:EXIT, _, _}
    refute_received {:DOWN, _, _, _, _}
    assert Process.info(self(), :links) == {:links, []}
  end
end
