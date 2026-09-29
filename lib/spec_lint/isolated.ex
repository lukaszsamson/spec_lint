defmodule SpecLint.Isolated do
  @moduledoc """
  Runs a function in a separate, monitored process that is not linked to
  the caller, and returns its crash as a value.

  The reachability check and rendering run away from the process that ran
  the analysis (`SpecLint.Reachability`, `SpecLint.Report`). With
  `Task.async/1` the new process is linked: when it crashes, the caller
  receives an exit signal that no `rescue` or `catch` stops, and Mix ends
  with status 1, the status of new gated findings, without writing a report
  (Milestone 5 review). `run/1` monitors the process instead, so a crash
  arrives as `{:error, {:crashed, reason}}` and the caller decides what it
  means: an incomplete run or an internal failure, both exit status 2.
  """

  @doc """
  Calls `fun` in a new process and waits for it. Returns `{:ok, value}`
  with its result, or `{:error, {:crashed, reason}}` when the process ended
  without one (an exception, an exit, a throw or a kill).
  """
  @spec run((-> value)) :: {:ok, value} | {:error, {:crashed, term()}} when value: term()
  def run(fun) when is_function(fun, 0) do
    caller = self()
    tag = make_ref()
    {pid, monitor} = spawn_monitor(fn -> send(caller, {tag, fun.()}) end)

    receive do
      {^tag, value} ->
        Process.demonitor(monitor, [:flush])
        {:ok, value}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, {:crashed, reason}}
    end
  end
end
