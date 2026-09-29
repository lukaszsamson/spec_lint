defmodule SpecLint.Report do
  @moduledoc """
  Renders the report of a finished run away from the process that ran it.

  The process that runs `SpecLint.Run.execute/3` ends up holding every
  analysed module's translated bounds: about 3.3 GB on Absinthe. Rendering
  prints the types of the findings, and printing a map type calls the
  struct module of every struct literal (`Module.Types.Descr` asks it for
  its fields), which loads that module on first use. Each code load in
  the large process was slow, and the time grew with its heap, not with
  the amount printed: the JSON report of Absinthe's nine findings took
  1-78 s there (47 s with 41 module loads in one measurement), against
  0.13 s in a fresh process (Milestone 1 review). The reporters' own
  modules, loaded lazily at the same point, added seconds more.

  `render/2` therefore renders in a short-lived process that receives only
  `view/1` of the run: the run without its per-module analysis results,
  which no reporter reads. The rendered report comes back as one binary.
  The process is monitored, not linked (`SpecLint.Isolated`): a crash while
  rendering raises in the caller, where the Mix tasks turn it into an
  internal failure (exit 2, no report).
  """

  alias SpecLint.Isolated
  alias SpecLint.Report.{Console, Json}
  alias SpecLint.Run

  @typedoc "Report format."
  @type format :: :console | :json

  @doc """
  Renders `run` as a console report or as the JSON envelope
  (`SpecLint.Report.Console.render/1`, `SpecLint.Report.Json.envelope/1`
  and `SpecLint.Report.Json.encode/1`) in a new process, and returns the
  report. The result is the same as rendering in the calling process.
  """
  @spec render(Run.t(), format()) :: binary()
  def render(%Run{} = run, format) when format in [:console, :json] do
    view = view(run)

    case Isolated.run(fn -> view |> render_iodata(format) |> IO.iodata_to_binary() end) do
      {:ok, report} -> report
      {:error, {:crashed, reason}} -> raise "rendering crashed: " <> crash_message(reason)
    end
  end

  @doc """
  The run without its analysis results (`modules`, `excluded`, `evidence`,
  `reachability` and the slice `inventory`): what the console and JSON
  reporters read, small enough to copy to another process.
  `SpecLint.Explain` and `mix spec_lint.baseline` need the analysis
  results and cannot use it.
  """
  @spec view(Run.t()) :: Run.t()
  def view(%Run{} = run),
    do: %{run | modules: [], excluded: [], evidence: %{}, reachability: %{}, inventory: []}

  defp crash_message({exception, stacktrace})
       when is_exception(exception) and is_list(stacktrace),
       do: Exception.message(exception)

  defp crash_message(reason), do: inspect(reason)

  defp render_iodata(run, :console), do: Console.render(run)
  defp render_iodata(run, :json), do: run |> Json.envelope() |> Json.encode()
end
