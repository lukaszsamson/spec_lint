defmodule SpecLint.EvidenceTest do
  use ExUnit.Case, async: true

  import SpecLint.TestHelpers

  alias SpecLint.{Analysis, Bound, Compare, Evidence, ExperimentFixtures}
  alias SpecLint.Compiler, as: C
  alias SpecLint.ExperimentFixtures.Cases

  defp exact_slice(args, ret),
    do: %{args: Enum.map(args, &Bound.exact/1), return: Bound.exact(ret)}

  defp relations(args, ret, clauses), do: Compare.slice(exact_slice(args, ret), clauses)

  defp views(descr), do: Enum.map(C.components(descr), &{&1.kind, &1.view})

  setup_all do
    result = Analysis.module(beam_path(Cases))
    assert result.status == :ok
    %{functions: Map.new(result.functions, &{&1.mfa, &1})}
  end

  describe "fixture corpus" do
    for {{_module, name, arity} = mfa, expected} <- ExperimentFixtures.expected() do
      @mfa mfa
      @expected expected
      test "#{name}/#{arity}: #{expected.class}", %{functions: functions} do
        function = Map.fetch!(functions, @mfa)
        assert function.status == :compared
        assert Evidence.classify_function(function.slices) == @expected.class

        if slices = @expected[:slices] do
          assert Enum.map(function.slices, &Evidence.classify(&1.relations).class) == slices
        end
      end
    end

    test "every spec'd fixture function has an expectation", %{functions: functions} do
      assert functions |> Map.keys() |> Enum.sort() ==
               ExperimentFixtures.expected() |> Map.keys() |> Enum.sort()
    end

    test "true omission components are structured and present in the contributing clause",
         %{functions: functions} do
      [slice] = functions[{Cases, :lookup, 1}].slices
      classification = Evidence.classify(slice.relations)

      assert [%{label: :structured, present_in_contributing?: true, kind: :tuple} = component] =
               classification.components

      assert component.descr_string == "{:error, :missing}"
      assert classification.reasons == []
    end

    test "a payload refined only by subtracting the spec does not count",
         %{functions: functions} do
      [slice] = functions[{Cases, :wrap_error, 1}].slices
      classification = Evidence.classify(slice.relations)
      assert classification.class == :unknown

      assert [
               %{
                 tag_in_spec?: true,
                 subtraction_payload?: true,
                 label: :structured,
                 present_in_contributing?: false
               }
             ] = classification.components

      assert {:tag_in_spec, 1} in classification.reasons
      assert {:subtraction_payload, 1} in classification.reasons

      [slice] = functions[{Cases, :lookup, 1}].slices
      assert [%{tag_in_spec?: false}] = Evidence.classify(slice.relations).components
    end

    test "overlapping overloads keep their class and carry the overlap reason",
         %{functions: functions} do
      [first, _second] = functions[{Cases, :pick, 1}].slices
      classification = Evidence.classify(first.relations)
      assert classification.class == :structured_possible
      assert :overlap in classification.reasons
    end

    test "domain escape and input approximation are recorded as reasons",
         %{functions: functions} do
      [display] = functions[{Cases, :display, 1}].slices
      assert {:domain_escape, [0]} in Evidence.classify(display.relations).reasons

      [sign] = functions[{Cases, :sign, 1}].slices
      reasons = Evidence.classify(sign.relations).reasons
      assert :input_approximate in reasons
      assert {:containment_unknown, [0]} in reasons
    end
  end

  describe "classify/2 on synthetic relations" do
    test "no extra is :none" do
      rel = relations([C.atom()], C.atom(), [{[C.atom()], C.atom([:a])}])
      assert %{class: :none, components: [], reasons: [:no_extra]} = Evidence.classify(rel)
    end

    test "badapply is :none" do
      rel = relations([C.atom()], C.atom(), [{[C.integer()], C.integer()}])
      assert %{class: :none, reasons: [:badapply]} = Evidence.classify(rel)
    end

    test "top-only inference is :unknown" do
      rel = relations([C.atom()], C.atom(), [{[C.atom()], C.dynamic()}])
      assert %{class: :unknown, reasons: [:top_only]} = Evidence.classify(rel)
    end

    test "structure only in the difference does not count" do
      clause_return = C.tuple([C.atom(), C.integer()])
      rel = relations([C.atom()], C.atom(), [{[C.atom()], clause_return}])
      # As if subtracting the spec had produced a tagged tuple.
      rel = %{rel | extra: C.tuple([C.atom([:error]), C.integer()])}

      assert %{class: :unknown, components: [component], reasons: reasons} =
               Evidence.classify(rel)

      assert %{label: :structured, present_in_contributing?: false} = component
      assert {:not_in_contributing, 1} in reasons
    end

    test "a term() payload under a declared tag is a subtraction payload" do
      # Phase 0 stdlib pattern: spec {:ok, pid()}, clause returns {:ok, term()}.
      spec = C.tuple([C.atom([:ok]), C.pid()])
      rel = relations([], spec, [{[], C.tuple([C.atom([:ok]), C.term()])}])

      assert %{class: :unknown, components: [component], reasons: reasons} =
               Evidence.classify(rel)

      assert %{label: :structured, tag_in_spec?: true, subtraction_payload?: true} = component
      refute component.present_in_contributing?
      assert {:subtraction_payload, 1} in reasons
    end

    test "a nested term() payload under a declared tag is a subtraction payload" do
      # JSON.decode/1: {:error, {:invalid_byte, integer(), not integer()}}.
      reason = &C.tuple([C.atom([:invalid_byte]), C.integer(), &1])
      spec = C.tuple([C.atom([:error]), reason.(C.integer())])
      clause_return = C.tuple([C.atom([:error]), reason.(C.term())])
      rel = relations([], spec, [{[], clause_return}])

      assert %{class: :unknown, components: [%{subtraction_payload?: true}]} =
               Evidence.classify(rel)
    end

    test "an inferred payload narrower than term() under a declared tag still counts" do
      spec = C.tuple([C.atom([:ok]), C.binary()])
      clause_return = C.tuple([C.atom([:ok]), C.union(C.binary(), C.integer())])
      rel = relations([], spec, [{[], clause_return}])

      assert %{class: :structured_possible, components: [component]} = Evidence.classify(rel)
      assert %{tag_in_spec?: true, subtraction_payload?: false} = component
      assert component.present_in_contributing?
    end

    test "one precise witness among term() payloads keeps the component" do
      spec = C.tuple([C.atom([:ok]), C.pid()])

      clauses = [
        {[C.atom([:a])], C.tuple([C.atom([:ok]), C.term()])},
        {[C.atom([:b])], C.tuple([C.atom([:ok]), C.atom([:x])])}
      ]

      rel = relations([C.atom([:a, :b])], spec, clauses)
      classification = Evidence.classify(rel)
      assert classification.class == :structured_possible
      assert Enum.all?(classification.components, &(not &1.subtraction_payload?))
    end

    test "a new tag is never a subtraction payload" do
      spec = C.tuple([C.atom([:ok]), C.pid()])
      clause_return = C.union(spec, C.tuple([C.atom([:error]), C.term()]))
      rel = relations([], spec, [{[], clause_return}])

      assert %{class: :structured_possible, components: [component]} = Evidence.classify(rel)
      assert %{tag_in_spec?: false, subtraction_payload?: false} = component
    end

    test "a structured extra split across several clauses is present" do
      clauses = [
        {[C.atom([:a])], C.tuple([C.atom([:error]), C.atom([:x])])},
        {[C.atom([:b])], C.tuple([C.atom([:error]), C.atom([:y])])}
      ]

      rel = relations([C.atom([:a, :b])], C.atom([:ok]), clauses)
      assert %{class: :structured_possible, components: components} = Evidence.classify(rel)
      assert Enum.all?(components, & &1.present_in_contributing?)
    end

    test "whole kind with an unknown component is :whole_kind_possible" do
      ret = C.union(C.integer(), C.difference(C.atom(), C.atom([nil])))
      rel = relations([C.atom()], C.boolean(), [{[C.atom()], ret}])
      classification = Evidence.classify(rel)
      assert classification.class == :whole_kind_possible
      assert {:unknown_components, 1} in classification.reasons

      assert Enum.sort(Enum.map(classification.components, & &1.label)) == [
               :unknown,
               :whole_kind
             ]
    end

    test "domain escape wins over input approximation" do
      slice = %{
        args: [%{Bound.exact(C.integer()) | losses: [Bound.loss(:integer_refinement_erased, [])]}],
        return: Bound.exact(C.atom([:ok]))
      }

      rel = Compare.slice(slice, [{[C.term()], C.atom([:ok, :error])}])
      assert rel.input_approximate?
      classification = Evidence.classify(rel)
      assert classification.class == :possible_domain_escape
      assert :input_approximate in classification.reasons
    end
  end

  describe "labels" do
    defp labels(descr), do: Enum.map(C.components(descr), &Evidence.label(&1, 3))

    test "structured shapes" do
      assert labels(C.atom([:a, :b])) == [:structured]
      assert labels(C.empty_list()) == [:structured]
      assert labels(C.tuple([C.atom([:error]), C.term()])) == [:structured]
      assert labels(C.closed_map([{:a, C.integer(), false}], [])) == [:structured]
      assert labels(C.empty_map()) == [:structured]
      assert labels(C.list(C.tuple([C.atom([:k]), C.integer()]))) == [:structured]

      struct = C.closed_map([{:__struct__, C.atom([URI]), false}, {:a, C.term(), false}], [])
      assert labels(struct) == [:structured]
    end

    test "whole kinds" do
      assert labels(C.integer()) == [:whole_kind]
      assert labels(C.binary()) == [:whole_kind]
      assert labels(C.tuple()) == [:whole_kind]
      assert labels(C.open_map()) == [:whole_kind]
      assert labels(C.fun()) == [:whole_kind]
      assert labels(C.atom()) == [:whole_kind]
      assert labels(C.list(C.term())) == [:whole_kind]
    end

    test "unknown shapes" do
      assert labels(C.tuple([C.atom(), C.integer()])) == [:unknown]
      assert labels(C.open_tuple([C.atom([:ok])])) == [:unknown]
      assert labels(C.list(C.integer())) == [:unknown]
      assert labels(C.closed_map([], [{[:atom], C.integer()}])) == [:unknown]
      assert labels(C.difference(C.atom(), C.atom([nil]))) == [:unknown]
      assert labels(C.difference(C.tuple(), C.tuple([C.atom([:ok])]))) == [:unknown]
      assert labels(C.fun(1)) == [:unknown]

      # A negation inside a component makes the whole component unknown.
      not_nil = C.difference(C.atom(), C.atom([nil]))
      assert labels(C.tuple([C.atom([:ok]), not_nil])) == [:unknown]
      assert labels(C.closed_map([{:a, not_nil, false}], [])) == [:unknown]
      assert labels(C.list(C.tuple([C.atom([:ok]), not_nil]))) == [:unknown]

      # ...unless it is expressible without one: term() minus a whole kind.
      assert labels(C.tuple([C.atom([:ok]), C.difference(C.term(), C.atom())])) == [:structured]
    end
  end

  describe "adapter components" do
    test "components cover the upper bound" do
      types = [
        C.term(),
        C.dynamic(C.union(C.atom([:a]), C.integer())),
        C.union(C.list(C.atom([:a])), C.tuple([C.atom([:ok]), C.binary()])),
        C.difference(C.term(), C.integer()),
        C.difference(C.tuple(), C.tuple([C.atom([:ok]), C.integer()]))
      ]

      for type <- types do
        union = type |> C.components() |> Enum.map(& &1.descr) |> C.union_all()
        assert C.equal?(union, C.upper_bound(type)), C.to_string(type)
      end
    end

    test "closed tuple negations of the same arity are eliminated" do
      whole = C.tuple([C.atom([:error]), C.atom([:a, :b])])
      diff = C.difference(whole, C.tuple([C.atom([:error]), C.atom([:a])]))
      assert [{:tuple, {:tuple, :closed, [tag, value]}}] = views(diff)
      assert C.equal?(tag, C.atom([:error]))
      assert C.equal?(value, C.atom([:b]))
    end

    test "empty types have no components" do
      assert C.components(C.none()) == []
    end

    test "lists carry the empty list" do
      assert [{:list, {:list, element, _tail, true}}] = views(C.list(C.atom([:a])))
      assert C.equal?(element, C.atom([:a]))
      assert views(C.empty_list()) == [{:list, :empty_list}]
    end
  end

  describe "classify_function/2" do
    test "worst class first" do
      assert Evidence.classify_function([:none, :unknown, :whole_kind_possible]) ==
               :whole_kind_possible

      assert Evidence.classify_function([:possible_input_approximate, :possible_domain_escape]) ==
               :possible_domain_escape

      assert Evidence.classify_function([:possible_domain_escape, :structured_possible]) ==
               :structured_possible

      assert Evidence.classify_function([%{relations: nil}]) == :none
      assert Evidence.classify_function([]) == :none
    end

    test "classes are ordered worst first" do
      assert Evidence.classes() == [
               :structured_possible,
               :possible_domain_escape,
               :possible_input_approximate,
               :whole_kind_possible,
               :unknown,
               :none
             ]
    end
  end
end
