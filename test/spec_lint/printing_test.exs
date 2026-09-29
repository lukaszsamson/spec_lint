defmodule SpecLint.PrintingTest do
  # Global state: the compiler adapter setting and VM-wide call counters.
  use ExUnit.Case, async: false

  import SpecLint.TestHelpers

  alias Module.Types.Descr
  alias SpecLint.{Analysis, Compare, Evidence, ExperimentFixtures, Issue}
  alias SpecLint.Compiler, as: C
  alias SpecLint.Report.{Console, Json}

  # Classification must not depend on printing (Milestone 1): this adapter
  # is the running compiler's qualified one except that it cannot print. Fingerprints still use
  # the structural canonical form (DESIGN 9.1).
  defmodule NoPrintAdapter do
    @moduledoc false
    @behaviour SpecLint.Compiler

    for {name, arity} <- SpecLint.Compiler.behaviour_info(:callbacks),
        name != :to_string do
      args = Macro.generate_arguments(arity, __MODULE__)

      @impl true
      def unquote(name)(unquote_splicing(args)),
        do: apply(SpecLint.Compiler.running_adapter(), unquote(name), [unquote_splicing(args)])
    end

    @impl true
    def to_string(_descr), do: raise("classification printed a type")
  end

  # The printer as it was before Milestone 1, which printed the direct and
  # the complement form in full and kept the shorter one. The current
  # adapter must print exactly the same strings. Set operations and the
  # expansion of term() and recursive nodes are the running adapter's
  # (Milestone 3: 1.20 has union/2 where 1.21 has opt_union/2, and no
  # public unfold/1).
  defmodule ReferencePrinter do
    @moduledoc false

    alias Module.Types.Descr

    defp ops, do: SpecLint.Compiler.running_adapter()
    defp intersection(left, right), do: ops().intersection(left, right)

    @spec to_string(term()) :: String.t()
    def to_string(descr) do
      cond do
        Descr.empty?(descr) -> "none()"
        Descr.gradual?(descr) -> quoted(descr)
        true -> canonical_or_complement(descr)
      end
    end

    defp quoted(descr), do: Descr.to_quoted_string(descr, skip_dynamic_for_indivisible: false)

    defp canonical_or_complement(descr) do
      complement = ops().difference(Descr.term(), descr)

      if Descr.empty?(complement) do
        "term()"
      else
        direct = normal_form_string(descr)
        negated = "not " <> parenthesise(normal_form_string(complement))
        if String.length(negated) < String.length(direct), do: negated, else: direct
      end
    end

    defp normal_form_string(descr) do
      static = ops().expand(descr)
      rest = Map.drop(static, [:tuple, :map])
      rest_string = if Descr.empty?(rest), do: [], else: [quoted(rest)]

      lines =
        Enum.flat_map([:tuple, :map], fn kind ->
          case Map.get(static, kind) do
            nil -> []
            bdd -> bdd |> Descr.bdd_to_dnf() |> Enum.reverse() |> Enum.flat_map(&line(kind, &1))
          end
        end)

      case rest_string ++ Enum.uniq(lines) do
        [single] -> single
        pieces -> Enum.map_join(pieces, " or ", &parenthesise_and/1)
      end
    end

    defp parenthesise(string) do
      if String.contains?(string, [" or ", " and "]), do: "(" <> string <> ")", else: string
    end

    defp parenthesise_and(string) do
      if String.contains?(string, " and not "), do: "(" <> string <> ")", else: string
    end

    # One change since Milestone 1 (Milestone 3 review): a line's top
    # literal is dropped when another positive remains (intersecting with
    # the top is the identity; 1.20.4 leaves it in some lines).
    defp line(kind, {pos, negs}) do
      top = top_literal(kind)

      positives =
        case Enum.reject(pos, &(&1 == top)) do
          [] -> [top]
          rest -> rest
        end

      pos_descr = positives |> Enum.map(&%{kind => &1}) |> Enum.reduce(&intersection/2)
      live = Enum.reject(negs, &Descr.disjoint?(pos_descr, %{kind => &1}))
      line = Enum.reduce(live, pos_descr, &ops().difference(&2, %{kind => &1}))

      if Descr.empty?(line) do
        []
      else
        positive = Enum.map_join(positives, " and ", &quoted(%{kind => &1}))

        case Enum.map(live, &quoted(%{kind => &1})) do
          [] -> [positive]
          [neg] -> [positive <> " and not " <> neg]
          negs -> [positive <> " and not (" <> Enum.join(negs, " or ") <> ")"]
        end
      end
    end

    defp top_literal(:tuple), do: Descr.tuple().tuple
    defp top_literal(:map), do: Descr.open_map().map
  end

  @fixture_modules [
    ExperimentFixtures.Cases,
    SpecLint.OmissionFixtures.Cases,
    SpecLint.OmissionFixtures.ClauseLocal,
    SpecLint.Fixtures.Compare,
    SpecLint.Fixtures.Review,
    SpecLint.Fixtures.Shadow,
    SpecLint.Fixtures.Siblings,
    SpecLint.Fixtures.ClauseLocal
  ]

  # Printer calls allowed to render every finding of a run over
  # @fixture_modules in one report. Measured when the budget was set
  # (Milestone 1): 40 findings, 122 adapter `to_string/1` calls and 238
  # `Descr.to_quoted_string/2` calls per report. A classifier that printed
  # again would print thousands.
  @render_budget %{adapter: 130, descr: 250}

  setup do
    previous = Application.get_env(:spec_lint, :compiler_adapter)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:spec_lint, :compiler_adapter, previous),
        else: Application.delete_env(:spec_lint, :compiler_adapter)
    end)
  end

  describe "classification does not print" do
    test "Evidence and Compare call no printer or serialiser" do
      forbidden = [
        {C, :to_string, 1},
        {C, :canonical, 1},
        {Issue, :render, 1},
        {Issue, :rendered_details, 1},
        {Descr, :to_quoted, 1},
        {Descr, :to_quoted, 2},
        {Descr, :to_quoted_string, 1},
        {Descr, :to_quoted_string, 2}
      ]

      for module <- [Evidence, Compare] do
        {:ok, {^module, [imports: imports]}} =
          :beam_lib.chunks(String.to_charlist(beam_path(module)), [:imports])

        assert imports != []
        assert Enum.filter(imports, &(&1 in forbidden)) == [], inspect(module)
      end
    end

    test "classifications are the same with an adapter that cannot print" do
      expected = classify_fixtures()

      with_adapter(NoPrintAdapter, fn ->
        assert classify_fixtures() == expected
      end)
    end

    test "a whole run has the same results with an adapter that cannot print" do
      expected = run!(@fixture_modules)

      with_adapter(NoPrintAdapter, fn ->
        run = run!(@fixture_modules)
        assert run.issues != []
        assert run.issues == expected.issues

        assert Enum.map(run.issues, & &1.fingerprint) ==
                 Enum.map(expected.issues, & &1.fingerprint)

        assert run.evidence == expected.evidence
        assert run.exit_code == expected.exit_code
        assert run.completion == expected.completion

        # The adapter really cannot print: rendering needs the printer.
        assert_raise RuntimeError, "classification printed a type", fn ->
          Enum.each(run.issues, &Issue.rendered_details/1)
        end
      end)
    end
  end

  describe "printing budget" do
    test "a run prints no type; rendering its findings stays within the budget" do
      # Preflight (memoised per VM) runs the printer option probe; the first
      # test of a VM to run it must not count it as the run's printing.
      assert {:ok, _capabilities} = C.preflight_once()
      {run, execute_calls} = counting(fn -> run!(@fixture_modules) end)
      assert run.issues != []
      assert execute_calls == %{adapter: 0, descr: 0}

      {_rendered, render_calls} =
        counting(fn ->
          json = run |> Json.envelope() |> Json.encode() |> IO.iodata_to_binary()
          console = run |> Console.render() |> IO.iodata_to_binary()
          {json, console}
        end)

      # Console and JSON render the same findings, so the budget is per
      # report.
      assert render_calls.adapter > 0
      assert render_calls.adapter <= 2 * @render_budget.adapter, inspect(render_calls)
      assert render_calls.descr <= 2 * @render_budget.descr, inspect(render_calls)
    end

    test "rendered details are the same strings as printing each type directly" do
      run = run!(@fixture_modules)

      for issue <- run.issues, {label, text} <- issue.details do
        assert {label, Issue.render(text)} in Issue.rendered_details(issue)
      end
    end
  end

  describe "printer" do
    test "prints exactly what printing both forms in full printed" do
      descrs = fixture_descrs()
      assert length(descrs) > 500

      for descr <- descrs do
        assert C.to_string(descr) == ReferencePrinter.to_string(descr)
      end
    end

    test "chooses the complement when it is shorter, also for short direct forms" do
      term = C.term()
      not_map_or_tuple = C.difference(term, C.union(C.open_map(), C.tuple()))
      assert C.to_string(not_map_or_tuple) == ReferencePrinter.to_string(not_map_or_tuple)
      assert C.to_string(not_map_or_tuple) =~ ~r/^not \(/

      not_atom = C.difference(term, C.atom([:a]))
      assert C.to_string(not_atom) == "not :a"
      assert C.to_string(C.atom([:a])) == ":a"
      assert C.to_string(term) == "term()"
      assert C.to_string(C.none()) == "none()"
    end
  end

  # Presentation difference between the lines (audit-1.20.4.md row 27, the
  # Milestone 3 review): 1.20.4 names the non-binary bitstring key domain
  # :bitstring and Descr prints it as `bitstring()`, so the same string
  # means a wider key set there. The views, which classification reads,
  # are the same on both lines. Pinned per adapter, not rewritten: the
  # printer shows what the running compiler's Descr prints.
  describe "the non-binary bitstring key domain" do
    setup do
      domain = C.closed_map([], [{[:bitstring_no_binary], C.integer()}])
      spec = C.closed_map([], [{[:bitstring_no_binary], C.atom()}, {[:binary], C.atom()}])

      assert [%{view: {:map, :closed, [], [{[:bitstring_no_binary], value}]}}] =
               C.components(domain)

      assert C.equal?(value, C.integer())
      %{domain: domain, spec: spec}
    end

    @tag adapter: SpecLint.Compiler.V120
    test "prints as bitstring() on 1.20.4", %{domain: domain, spec: spec} do
      assert C.to_string(domain) == "%{bitstring() => integer()}"
      assert C.to_string(spec) == "%{binary() => atom(), bitstring() => atom()}"
    end

    @tag adapter: SpecLint.Compiler.V121
    test "prints as (bitstring() and not binary()) on 1.21", %{domain: domain, spec: spec} do
      assert C.to_string(domain) == "%{(bitstring() and not binary()) => integer()}"
      assert C.to_string(spec) == "%{bitstring() => atom()}"
    end
  end

  defp classify_fixtures do
    for module <- @fixture_modules,
        function <- Analysis.module(beam_path(module)).functions,
        slice <- function.slices,
        slice.relations != nil do
      {function.mfa, slice.index, Evidence.classify(slice.relations),
       Evidence.classify(slice.relations, require_static_return: true)}
    end
  end

  # Every type the reporters and --explain may print for the modules of
  # this build (SpecLint itself and the fixtures).
  defp fixture_descrs do
    for path <- Path.wildcard(Path.join(Mix.Project.compile_path(), "*.beam")),
        function <- Analysis.module(path).functions,
        slice <- function.slices,
        rel = slice.relations,
        rel != nil,
        evidence = Evidence.classify(rel),
        descr <-
          [rel.extra, rel.applied_upper, rel.spec_return, rel.missing] ++
            Enum.map(slice.args, & &1.hi) ++
            Enum.map(evidence.components, & &1.descr) ++
            Enum.flat_map(
              evidence.clauses,
              &[&1.extra | Enum.map(&1.components, fn c -> c.descr end)]
            ) ++
            Enum.flat_map(rel.contributing, &[&1.return | &1.args]),
        uniq: true,
        do: descr
  end

  defp with_adapter(adapter, fun) do
    Application.put_env(:spec_lint, :compiler_adapter, adapter)

    try do
      fun.()
    after
      Application.delete_env(:spec_lint, :compiler_adapter)
    end
  end

  # Counts, in every process, calls of the adapter's printer and of the
  # compiler's own printer while `fun` runs.
  defp counting(fun) do
    adapter = {SpecLint.Compiler.running_adapter(), :to_string, 1}
    descr = {Descr, :to_quoted_string, 2}
    mfas = [adapter, descr]

    Enum.each(mfas, &:erlang.trace_pattern(&1, true, [:call_count]))

    try do
      result = fun.()
      counts = Enum.map(mfas, &call_count/1)
      {result, %{adapter: Enum.at(counts, 0), descr: Enum.at(counts, 1)}}
    after
      Enum.each(mfas, &:erlang.trace_pattern(&1, false, [:call_count]))
    end
  end

  defp call_count(mfa) do
    {:call_count, count} = :erlang.trace_info(mfa, :call_count)
    count
  end
end
