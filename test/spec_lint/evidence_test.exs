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

        assert Evidence.classify_function(function.slices, require_static_return: true) ==
                 (@expected[:static_class] || @expected.class)

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

      assert C.to_string(component.descr) == "{:error, :missing}"
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
      assert classification.union_class == :structured_possible
      assert classification.class == :clause_conflict
      assert :overlap in classification.reasons
    end

    test "a stale spec hidden by a top-only union is a clause conflict",
         %{functions: functions} do
      [slice] = functions[{Cases, :stale, 1}].slices
      classification = Evidence.classify(slice.relations)
      assert classification.union_class == :unknown
      assert :top_only in classification.reasons
      assert classification.class == :clause_conflict

      conflicts = for %{class: :clause_conflict} = clause <- classification.clauses, do: clause
      assert [_ | _] = conflicts
      assert Enum.all?(conflicts, &(&1.containment == :contained and :disjoint in &1.reasons))

      assert Enum.any?(
               classification.clauses,
               &(&1.class == :unknown and :top_only in &1.reasons)
             )
    end

    test "near-top inference is treated like top-only", %{functions: functions} do
      [slice] = functions[{Cases, :put_setting, 2}].slices
      assert slice.relations.near_top?
      refute slice.relations.top_only?
      classification = Evidence.classify(slice.relations)
      assert %{class: :unknown, union_class: :unknown, components: []} = classification
      assert :near_top in classification.reasons
      assert Enum.all?(classification.clauses, &(:near_top in &1.reasons))
    end

    test "a structured component witnessed only by a gradual return is payload_gradual",
         %{functions: functions} do
      [slice] = functions[{Cases, :gradual_payload, 1}].slices
      default = Evidence.classify(slice.relations)
      assert default.class == :structured_possible
      assert [%{label: :structured, payload_gradual?: true}] = default.components
      assert {:payload_gradual, 1} in default.reasons

      static = Evidence.classify(slice.relations, require_static_return: true)
      assert static.class == :possible_gradual
      assert static.union_class == :possible_gradual
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

      assert %{union_class: :unknown, components: [component], reasons: reasons} =
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
      assert classification.union_class == :structured_possible
      assert Enum.all?(classification.components, &(not &1.subtraction_payload?))
      # The {:ok, :x} clause alone is entirely outside the spec.
      assert classification.class == :clause_conflict
    end

    test "a new tag is never a subtraction payload" do
      spec = C.tuple([C.atom([:ok]), C.pid()])
      clause_return = C.union(spec, C.tuple([C.atom([:error]), C.term()]))
      rel = relations([], spec, [{[], clause_return}])

      assert %{class: :structured_possible, components: [component]} = Evidence.classify(rel)
      assert %{tag_in_spec?: false, subtraction_payload?: false} = component
    end

    test "a payload narrowed by the subtraction still counts when the code puts it outside" do
      # Spec {:ok, pid(), :a}; the clause returns {:ok, term(), :a or :b}.
      # {:ok, pid(), :b} has a pid() from the subtraction but a :b from the
      # code: widened back to {:ok, term(), :b} it is still outside the spec.
      spec = C.tuple([C.atom([:ok]), C.pid(), C.atom([:a])])
      clause_return = C.tuple([C.atom([:ok]), C.term(), C.atom([:a, :b])])
      rel = relations([], spec, [{[], clause_return}])
      classification = Evidence.classify(rel)
      assert classification.class == :structured_possible

      assert %{true: [artefact], false: [counted]} =
               Enum.group_by(classification.components, & &1.subtraction_payload?)

      assert %{tag_in_spec?: true, present_in_contributing?: false} = artefact
      assert %{tag_in_spec?: true, present_in_contributing?: true} = counted
      assert C.to_string(counted.descr) =~ ":b"
      assert {:subtraction_payload, 1} in classification.reasons

      # The same code-derived position one level down.
      nested = &C.tuple([C.atom([:ok]), C.tuple([C.atom([:v]), &1, &2])])
      spec = nested.(C.pid(), C.atom([:a]))
      rel = relations([], spec, [{[], nested.(C.term(), C.atom([:a, :b]))}])
      assert Evidence.classify(rel).class == :structured_possible

      # A nested payload that only the subtraction narrowed stays an artefact.
      rel = relations([], spec, [{[], nested.(C.term(), C.atom([:a]))}])

      assert %{class: :unknown, components: [%{subtraction_payload?: true}]} =
               Evidence.classify(rel)
    end

    test "a structured extra split across several clauses is present" do
      clauses = [
        {[C.atom([:a])], C.tuple([C.atom([:error]), C.atom([:x])])},
        {[C.atom([:b])], C.tuple([C.atom([:error]), C.atom([:y])])}
      ]

      rel = relations([C.atom([:a, :b])], C.atom([:ok]), clauses)

      assert %{union_class: :structured_possible, components: components} =
               Evidence.classify(rel)

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

  describe "per-clause evidence" do
    test "a precise clause disjoint from the spec under a top-only union is a conflict" do
      clauses = [
        {[C.atom()], C.tuple([C.atom([:a]), C.atom([:b])])},
        {[C.integer()], C.dynamic()}
      ]

      rel = relations([C.union(C.atom(), C.integer())], C.atom([:ok]), clauses)
      assert rel.top_only?

      assert %{class: :clause_conflict, union_class: :unknown, clauses: [first, second]} =
               Evidence.classify(rel)

      assert %{index: 0, class: :clause_conflict, containment: :contained} = first
      assert :disjoint in first.reasons
      assert C.equal?(first.extra, C.tuple([C.atom([:a]), C.atom([:b])]))
      assert %{index: 1, class: :unknown, reasons: [:top_only]} = second
    end

    test "the stored clause return is used, not the wrapped application result" do
      # The stored return is static; its application is dynamic(...).
      clauses = [{[C.atom()], C.integer()}]
      rel = relations([C.atom()], C.atom(), clauses)
      assert C.gradual?(rel.applied_return)

      assert %{class: :clause_conflict, clauses: [%{static_return?: true}]} =
               Evidence.classify(rel)
    end

    test "an escaping or approximately contained clause is never a conflict" do
      escape = relations([C.atom()], C.atom(), [{[C.term()], C.integer()}])

      assert %{class: :possible_domain_escape, clauses: [clause]} = Evidence.classify(escape)
      assert %{class: :possible_domain_escape, containment: :domain_escape} = clause
      assert :disjoint in clause.reasons

      approximate = %{
        args: [
          %Bound{
            lo: C.none(),
            hi: C.integer(),
            losses: [Bound.loss(:integer_refinement_erased, [])]
          }
        ],
        return: Bound.exact(C.atom([:ok]))
      }

      rel = Compare.slice(approximate, [{[C.integer()], C.binary()}])
      assert %{class: class, clauses: [clause]} = Evidence.classify(rel)
      assert class == :possible_input_approximate
      assert %{class: :possible_input_approximate, containment: :containment_unknown} = clause
    end

    test "structure only in the subtraction does not count per clause (F1)" do
      spec = C.tuple([C.atom([:ok]), C.pid()])
      clauses = [{[C.atom()], C.tuple([C.atom([:ok]), C.term()])}, {[C.integer()], C.dynamic()}]
      rel = relations([C.union(C.atom(), C.integer())], spec, clauses)

      assert %{class: :unknown, clauses: [first, _second]} = Evidence.classify(rel)
      assert %{class: :unknown, components: [%{subtraction_payload?: true}]} = first
    end

    test "a structured per-clause extra is structured_possible" do
      ret = C.union(C.atom([:ok]), C.tuple([C.atom([:error]), C.atom([:x])]))
      clauses = [{[C.atom()], ret}, {[C.integer()], C.dynamic()}]
      rel = relations([C.union(C.atom(), C.integer())], C.atom([:ok]), clauses)

      assert %{class: :structured_possible, union_class: :unknown, clauses: [first, _]} =
               Evidence.classify(rel)

      assert %{class: :structured_possible, components: [%{label: :structured}]} = first
    end

    test "a no_return() spec never yields a clause conflict" do
      rel = relations([C.atom()], C.none(), [{[C.atom()], C.atom([:ok])}])
      assert rel.spec_return_empty?
      classification = Evidence.classify(rel)
      refute classification.class == :clause_conflict
      assert :spec_return_empty in classification.reasons
    end

    test "require_static_return downgrades a conflict with a gradual clause return" do
      clauses = [{[C.atom()], C.dynamic(C.integer())}]
      rel = relations([C.atom()], C.atom(), clauses)
      assert Evidence.classify(rel).class == :clause_conflict

      assert %{class: :possible_gradual, clauses: [clause]} =
               Evidence.classify(rel, require_static_return: true)

      assert :payload_gradual in clause.reasons

      static = relations([C.atom()], C.atom(), [{[C.atom()], C.integer()}])
      assert Evidence.classify(static, require_static_return: true).class == :clause_conflict
    end

    test "require_static_return keeps a structured component a static clause witnesses" do
      extra = C.tuple([C.atom([:error]), C.atom([:x])])

      clauses = [
        {[C.atom([:a])], C.union(C.atom([:ok]), extra)},
        {[C.atom([:b])], C.dynamic(C.union(C.atom([:ok]), extra))}
      ]

      rel = relations([C.atom([:a, :b])], C.atom([:ok]), clauses)
      classification = Evidence.classify(rel, require_static_return: true)
      assert classification.union_class == :structured_possible
      assert [%{payload_gradual?: false}] = classification.components
    end
  end

  describe "near-top and whole kinds" do
    test "term() minus a finite atom set is near-top" do
      ret = C.dynamic(C.difference(C.term(), C.atom([:undefined])))
      rel = relations([C.atom()], C.list(C.tuple([C.atom(), C.term()])), [{[C.atom()], ret}])
      assert rel.near_top?
      assert %{class: :unknown, reasons: [:near_top]} = Evidence.classify(rel)
    end

    test "an extra covering pid, port, reference and fun is near-top" do
      ret = C.dynamic(C.difference(C.term(), C.empty_list()))
      rel = relations([C.atom()], C.list(C.tuple([C.atom(), C.term()])), [{[C.atom()], ret}])
      assert rel.near_top?
      assert %{class: :unknown, reasons: [:near_top]} = Evidence.classify(rel)

      # Not near-top when the spec itself declares those kinds.
      spec = C.union_all([C.pid(), C.port(), C.reference(), C.fun()])
      ret = C.union(spec, C.integer())
      rel = relations([C.atom()], spec, [{[C.atom()], ret}])
      refute rel.near_top?
      assert Evidence.classify(rel).class == :whole_kind_possible
    end

    test "whole-kind evidence respects input approximation and domain escape (O6)" do
      approximate = %{
        args: [
          %Bound{
            lo: C.none(),
            hi: C.integer(),
            losses: [Bound.loss(:integer_refinement_erased, [])]
          }
        ],
        return: Bound.exact(C.empty_list())
      }

      rel = Compare.slice(approximate, [{[C.integer()], C.list(C.term())}])

      assert %{union_class: :possible_input_approximate, reasons: reasons} =
               Evidence.classify(rel)

      assert :whole_kind_only in reasons

      escape = relations([C.atom()], C.integer(), [{[C.term()], C.union(C.integer(), C.float())}])

      assert %{union_class: :possible_domain_escape, reasons: reasons} =
               Evidence.classify(escape)

      assert :whole_kind_only in reasons

      contained =
        relations([C.atom()], C.integer(), [{[C.atom()], C.union(C.integer(), C.float())}])

      assert Evidence.classify(contained).class == :whole_kind_possible
    end

    test "Macro.generate_unique_arguments/2 shape: slice 0 is input-approximate" do
      function = analysed(SpecLint.Fixtures.Compare, :unique_args, 2)
      [zero, _positive] = function.slices
      classification = Evidence.classify(zero.relations)
      assert classification.class == :possible_input_approximate
      assert :whole_kind_only in classification.reasons
      refute :overlap in classification.reasons
      refute :overlap_unknown in classification.reasons
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
               :clause_conflict,
               :structured_possible,
               :possible_gradual,
               :possible_domain_escape,
               :possible_input_approximate,
               :whole_kind_possible,
               :unknown,
               :none
             ]
    end
  end

  # 1.20.4's Descr leaves the open-map top literal as a second positive of
  # term() - (term() - %{binary() => term()}); read as an intersection, it
  # made a parent struct or tuple unknown (Milestone 3 review). The type is
  # the plain domain map, and must be labelled and printed as one under
  # every adapter.
  describe "a DNF line that repeats the top literal" do
    test "is the plain literal: structured parents, printed without the top" do
      term = C.term()
      domain_map = C.closed_map([], [{[:binary], term}])
      twice_negated = C.difference(term, C.difference(term, domain_map))
      assert C.equal?(twice_negated, domain_map)

      field =
        C.closed_map([{:__struct__, C.atom([Foo]), false}, {:opts, twice_negated, false}], [])

      element = C.tuple([C.atom([:ok]), twice_negated])

      for parent <- [field, element] do
        assert [component] = C.components(parent)
        assert Evidence.label(component, 2) == :structured
      end

      assert views(twice_negated) == views(domain_map)
      assert C.to_string(twice_negated) == "%{binary() => term()}"
      assert C.to_string(C.difference(term, twice_negated)) == "not %{binary() => term()}"
      assert C.to_string(field) == "%{__struct__: Foo, opts: %{binary() => term()}}"
    end
  end
end
