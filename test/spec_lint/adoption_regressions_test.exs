defmodule SpecLint.AdoptionRegressionsTest do
  @moduledoc """
  Adoption regressions: findings from trials on private projects, kept as
  anonymised fixtures (`SpecLint.AdoptionFixtures`). They are not part of
  the evaluation inventory (bench/), whose 18-family denominator they leave
  unchanged.
  """

  use ExUnit.Case, async: true

  import SpecLint.TestHelpers

  alias SpecLint.AdoptionFixtures.{Charges, Consumer, Evaluated, Order}
  alias SpecLint.{Analysis, Config, Evidence, InheritedSpec, Issue, Policy}

  describe "an omitted error tuple in the first of three clauses" do
    test "the in-domain witness returns the undeclared value" do
      # A spec-conforming input: the struct type admits status: :inactive.
      assert Charges.charge(%Order{id: 1, status: :inactive}, 10) == {:error, :order_inactive}

      # The declared returns come from the other clauses.
      assert Charges.charge(%Order{status: :active}, 10) == {:ok, 10}
      assert Charges.charge(%Order{status: :active}, 0) == {:error, :insufficient_funds}
    end

    test "is classified possible_domain_escape, reported and not gated" do
      result = Analysis.module(beam_path(Charges))
      function = Enum.find(result.functions, &(&1.mfa == {Charges, :charge, 2}))
      assert function.status == :compared

      # Current class (recorded, not the desired one): the omission is only
      # found as a possible domain escape.
      assert Evidence.classify_function(function.slices) == :possible_domain_escape

      run = run!([Charges])

      assert [%Issue{rule: "SL002", evidence: :possible_domain_escape} = issue] =
               issues(run, {Charges, :charge, 2})

      refute issue.gate
      refute Policy.gate?(issue, %Config{profile: :review})
      refute issue.data[:inherited_spec]
      refute Enum.any?(Issue.rendered_details(issue), fn {label, _} -> label == "note" end)
    end
  end

  describe "a spec injected by a library macro" do
    test "the injected spec carries a bare line, a written spec carries a column" do
      injected = spec_clauses(Consumer, :template_not_found, 2)
      written = spec_clauses(Consumer, :own_spec, 1)

      assert [{:type, line, :fun, _}] = injected
      assert is_integer(line)
      assert [{:type, {_line, _column}, :fun, _}] = written

      function = analysed(Consumer, :template_not_found, 2)
      assert function.definition_column?
      assert is_integer(function.module_line) and function.module_line < line
      assert InheritedSpec.detect(hd(injected), function) == {:inherited, line}
      assert InheritedSpec.detect(hd(written), function) == :not_detected

      # Without columns, or without the module line, nothing can be said.
      assert InheritedSpec.detect(hd(injected), %{function | definition_column?: false}) ==
               :not_detected

      assert InheritedSpec.detect(hd(injected), %{function | module_line: nil}) == :not_detected
    end

    # Review finding: a spec the module evaluates from an AST without line
    # metadata carries the bare line 1 (here the line of another module in
    # the file) and was reported as injected at "line 1".
    test "a spec the module evaluates from an AST is not reported as inherited" do
      [{:type, line, :fun, _} = spec] = spec_clauses(Evaluated, :from_quote, 1)
      function = analysed(Evaluated, :from_quote, 1)
      assert line == 1
      assert function.definition_column?
      assert function.module_line > line
      assert InheritedSpec.detect(spec, function) == :not_detected

      run = run!([Evaluated])

      for issue <- issues(run, {Evaluated, :from_quote, 1}) do
        refute issue.data[:inherited_spec]
      end
    end

    test "a spec injected with quote location: :keep carries the call line" do
      [spec] = spec_clauses(Evaluated, :kept, 1)
      function = analysed(Evaluated, :kept, 1)
      source = File.read!(Evaluated.module_info(:compile)[:source] |> List.to_string())

      call_line =
        source |> String.split("\n") |> Enum.find_index(&(&1 =~ "  KeepLibrary.kept_spec()"))

      assert InheritedSpec.detect(spec, function) == {:inherited, call_line + 1}
    end

    test "the spec line is the use line, not the definition line" do
      [{:type, spec_line, :fun, _}] = spec_clauses(Consumer, :template_not_found, 2)
      function = analysed(Consumer, :template_not_found, 2)

      source = File.read!(Consumer.module_info(:compile)[:source] |> List.to_string())

      use_line =
        source |> String.split("\n") |> Enum.find_index(&(&1 =~ "use SpecLint.")) |> Kernel.+(1)

      assert spec_line == use_line
      assert function.line != spec_line
    end

    test "SL006 notes the inherited spec without changing gating or the fingerprint" do
      run = run!([Consumer])
      assert [issue] = issues(run, {Consumer, :template_not_found, 2})
      assert %Issue{rule: "SL006", evidence: :unexpected_return} = issue

      assert issue.data.inherited_spec == true
      assert is_integer(issue.data.inherited_spec_line)

      assert {"note", note} = List.keyfind(Issue.rendered_details(issue), "note", 0)
      assert note =~ "not written next to the definition"
      assert note =~ "Baseline"

      # Gated exactly as before (SL006 gates in the review profile).
      assert Policy.gate?(issue, %Config{profile: :review})

      # The own spec, written next to its definition, is not marked.
      assert [_ | _] = own = issues(run, {Consumer, :own_spec, 1})

      for other <- own do
        refute other.data[:inherited_spec]
      end
    end
  end
end
