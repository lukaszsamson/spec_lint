# Module.Types.Descr.to_quoted_string/2 attempts a module load for every
# closed map literal that has a single-atom :__struct__ field
# (`maybe_struct/1` calls `struct.__info__(:struct)`), on every print. When
# the module is not loadable that is a failed load through the code server
# each time, and its cost grows with the length of the code path.
#
#     elixir repro.exs                     # the Elixir on PATH
#     /path/to/build/bin/elixir repro.exs  # a given build
#
# Prints, per case, microseconds per print and the number of calls to
# :error_handler.undefined_function/3 and :code.ensure_loaded/1 (a call
# count is stable across machines, the timings are not), and a final
#
#     VERDICT: reproduces | does not reproduce | not applicable (...)
#
# reproduces = one failed load per print of a map type whose struct module
# does not exist.

import Module.Types.Descr

info = System.build_info()
IO.puts("Elixir #{System.version()} revision #{info[:revision]} OTP #{info[:otp_release]}")

try do
  # The probe builds types with the 1.21 Descr constructors.
  if Version.compare(System.version(), "1.21.0-dev") == :lt do
    IO.puts("VERDICT: not applicable (Module.Types.Descr constructors differ before 1.21)")
    System.halt(0)
  end

  n = 2_000

  plain = closed_map([{:a, {integer(), false}}, {:b, {atom(), false}}])

  absent =
    closed_map([
      {:__struct__, {atom([This.Struct.Module.Does.Not.Exist]), false}},
      {:a, {integer(), false}},
      {:b, {atom(), false}}
    ])

  loaded = closed_map([{:__struct__, {atom([URI]), false}}, {:a, {integer(), false}}])

  IO.puts("absent struct prints as: #{to_quoted_string(absent)}")

  probes = [{:error_handler, :undefined_function, 3}, {:code, :ensure_loaded, 1}]

  measure = fn label, type ->
    Enum.each(probes, &:erlang.trace_pattern(&1, true, [:call_count]))
    {us, _} = :timer.tc(fn -> for _ <- 1..n, do: to_quoted_string(type) end)

    [failed, ensure] =
      for probe <- probes do
        {:call_count, count} = :erlang.trace_info(probe, :call_count)
        count
      end

    Enum.each(probes, &:erlang.trace_pattern(&1, false, [:call_count]))

    IO.puts(
      "  #{String.pad_trailing(label, 22)} #{String.pad_leading(Float.to_string(Float.round(us / n, 1)), 9)} us/print" <>
        "  undefined_function calls: #{failed}  ensure_loaded calls: #{ensure}  (#{n} prints)"
    )

    failed
  end

  # Make sure the probed modules are loaded so call counting applies.
  Enum.each([:error_handler, :code], &Code.ensure_loaded/1)

  # Extra (empty) directories on the code path stand for the ebin
  # directories of a real project's dependencies.
  base = Path.join(System.tmp_dir!(), "printer_load_#{System.unique_integer([:positive])}")

  results =
    try do
      for extra <- [0, 100, 300] do
        for i <- 1..extra//1 do
          dir = Path.join(base, "d#{extra}_#{i}/ebin")
          File.mkdir_p!(dir)
          Code.prepend_path(dir)
        end

        IO.puts("code path length #{length(:code.get_path())}")
        measure.("plain map", plain)
        measure.("struct, loaded", loaded)
        {extra, measure.("struct, module absent", absent)}
      end
    after
      File.rm_rf!(base)
    end

  verdict =
    if Enum.all?(results, fn {_extra, failed} -> failed >= n end),
      do: "reproduces",
      else: "does not reproduce"

  IO.puts("VERDICT: #{verdict}")
rescue
  error in [UndefinedFunctionError, FunctionClauseError, ArgumentError, MatchError] ->
    IO.puts("not applicable: #{Exception.message(error) |> String.split("\n") |> hd()}")
    IO.puts("VERDICT: not applicable (Module.Types.Descr API differs)")

  error ->
    IO.puts(:stderr, "harness failure: #{Exception.message(error)}")
    System.halt(2)
end
