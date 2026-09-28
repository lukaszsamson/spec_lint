defmodule SpecLint.StderrShell do
  @moduledoc """
  A `Mix.Shell` that writes everything to standard error.

  `mix spec_lint --format json` without `--output` writes the report to
  standard output, so compiler progress (`Compiling 2 files (.ex)`,
  `Generated app`) and anything else Mix prints while the project compiles
  must not go there. `with_shell/1` installs this shell for the duration of
  a function and restores the previous one afterwards.
  """

  @behaviour Mix.Shell

  @doc "Runs `fun` with this shell installed as `Mix.shell/0`, then restores the previous one."
  @spec with_shell((-> result)) :: result when result: var
  def with_shell(fun) do
    previous = Mix.shell()
    Mix.shell(__MODULE__)

    try do
      fun.()
    after
      Mix.shell(previous)
    end
  end

  @impl true
  @spec print_app() :: :ok
  def print_app do
    if name = Mix.Shell.printable_app_name() do
      IO.puts(:stderr, "==> #{name}")
    end

    :ok
  end

  @impl true
  @spec info(IO.ANSI.ansidata()) :: :ok
  def info(message) do
    print_app()
    IO.puts(:stderr, IO.ANSI.format(message))
  end

  @impl true
  @spec error(IO.ANSI.ansidata()) :: :ok
  def error(message) do
    print_app()
    IO.puts(:stderr, IO.ANSI.format([:red, :bright, message]))
  end

  @impl true
  @spec prompt(String.t()) :: String.t()
  def prompt(message) do
    print_app()

    case IO.gets(:stdio, message <> " ") do
      answer when is_binary(answer) -> answer
      _ -> ""
    end
  end

  @impl true
  @spec yes?(String.t()) :: boolean()
  def yes?(message), do: yes?(message, [])

  @impl true
  @spec yes?(String.t(), keyword()) :: boolean()
  def yes?(_message, options) do
    # Never prompts: a report on standard output must not be interleaved
    # with questions. The default answer is taken.
    Keyword.get(options, :default, :yes) == :yes
  end

  @impl true
  @spec cmd(String.t()) :: non_neg_integer()
  def cmd(command), do: cmd(command, [])

  @impl true
  @spec cmd(String.t(), keyword()) :: non_neg_integer()
  def cmd(command, options) do
    print_app? = Keyword.get(options, :print_app, true)

    Mix.Shell.cmd(command, options, fn data ->
      if print_app?, do: print_app()
      IO.write(:stderr, data)
    end)
  end
end
