defmodule SpecLint.TranslateTest do
  use ExUnit.Case, async: true

  import SpecLint.TestHelpers

  alias SpecLint.{Bound, Translate, TypeCache}
  alias SpecLint.Compiler, as: C
  alias SpecLint.Fixtures.{Remote, Types}

  defp assert_exact(%Bound{} = bound, expected) do
    assert bound.losses == []
    assert C.equal?(bound.hi, expected), "hi: #{C.to_string(bound.hi)}"
    assert C.equal?(bound.lo, expected), "lo: #{C.to_string(bound.lo)}"
  end

  defp assert_bounds(%Bound{} = bound, lo, hi, kinds) do
    assert C.equal?(bound.hi, hi), "hi: #{C.to_string(bound.hi)}"
    assert C.equal?(bound.lo, lo), "lo: #{C.to_string(bound.lo)}"
    assert loss_kinds(bound.losses) == Enum.sort(kinds)
    assert C.subtype?(bound.lo, bound.hi)
  end

  defp raw(ast, module \\ Types) do
    {:ok, bound} = Translate.type(ast, context(module), [:root])
    bound
  end

  describe "literals and base types" do
    test "atom literal is exact" do
      %{args: [arg], return: ret} = slice(Types, :literal_atom, 1)
      assert_exact(arg, C.atom([:a]))
      assert_exact(ret, C.atom([:a]))
    end

    test "integer refinements erase to integer() upper bounds" do
      %{args: args, return: ret} = slice(Types, :refined, 5)

      for {bound, index} <- Enum.with_index(args) do
        assert_bounds(bound, C.none(), C.integer(), [:integer_refinement_erased])
        assert [%{path: [{:arg, ^index}]}] = bound.losses
      end

      assert_bounds(ret, C.none(), C.integer(), [:integer_refinement_erased])
      assert [%{path: [:return]}] = ret.losses
    end

    test "sized binaries" do
      %{args: [byte, binary, bitstring, nonempty], return: ret} = slice(Types, :sized, 4)
      assert_bounds(byte, C.none(), C.binary(), [:sized_binary_erased])
      assert_exact(binary, C.binary())
      assert_exact(bitstring, C.bitstring())
      assert_bounds(nonempty, C.none(), C.binary(), [:sized_binary_erased])
      assert_bounds(ret, C.none(), C.bitstring(), [:sized_binary_erased])
    end

    test "charlists and keywords" do
      %{args: [charlist, nonempty, keyword, keyword_of]} = slice(Types, :charlists, 4)
      assert_bounds(charlist, C.empty_list(), C.list(C.integer()), [:charlist_as_integers])

      assert_bounds(
        nonempty,
        C.none(),
        C.non_empty_list(C.integer(), C.empty_list()),
        [:charlist_as_integers]
      )

      assert_exact(keyword, C.list(C.tuple([C.atom(), C.term()])))
      assert_exact(keyword_of, C.list(C.tuple([C.atom(), C.integer()])))
    end

    test "timeout and mfa keep exact parts" do
      %{args: [timeout, mfa]} = slice(Types, :timeout_mfa, 2)

      assert_bounds(
        timeout,
        C.atom([:infinity]),
        C.union(C.integer(), C.atom([:infinity])),
        [:integer_refinement_erased]
      )

      assert_bounds(
        mfa,
        C.none(),
        C.tuple([C.atom(), C.atom(), C.integer()]),
        [:integer_refinement_erased]
      )

      assert [%{path: [{:arg, 1}, {:elem, 2}]}] = mfa.losses
    end

    test "records are open tuples tagged by name" do
      bound = raw({:type, 0, :record, [{:atom, 0, :person}]})

      assert_bounds(
        bound,
        C.none(),
        C.open_tuple([C.atom([:person])]),
        [:record_fields_unknown]
      )
    end
  end

  describe "lists" do
    test "proper, non-empty and improper lists" do
      %{args: [ints, atoms, maybe], return: ret} = slice(Types, :lists, 3)
      assert_exact(ints, C.list(C.integer()))
      assert_exact(atoms, C.non_empty_list(C.atom(), C.empty_list()))

      assert_exact(
        maybe,
        C.union(
          C.empty_list(),
          C.non_empty_list(C.integer(), C.union(C.atom(), C.empty_list()))
        )
      )

      assert_exact(ret, C.non_empty_list(C.atom(), C.binary()))
    end

    test "iolist over-approximation includes improper lists" do
      %{args: [iolist], return: iodata} = slice(Types, :io, 1)
      assert loss_kinds(iolist.losses) == [:recursive_cutoff]
      assert loss_kinds(iodata.losses) == [:recursive_cutoff]

      # [?a | "bc"] is an iolist. A proper_list(term()) mapping would
      # under-approximate and fabricate contradictions.
      improper = C.non_empty_list(C.integer(), C.binary())
      assert C.subtype?(improper, iolist.hi)
      refute C.subtype?(improper, C.list(C.term()))
      assert C.subtype?(C.empty_list(), iolist.lo)
      assert C.subtype?(C.binary(), iodata.hi)
      assert C.subtype?(improper, iodata.hi)
      refute C.subtype?(C.atom(), iodata.hi)
    end
  end

  describe "maps" do
    test "optional whole-kind keys are exact, required ones are widened" do
      %{args: [open_atoms, strings, struct], return: ret} = slice(Types, :maps, 3)

      assert open_atoms.losses == []
      assert C.subtype?(C.empty_map(), open_atoms.hi)
      assert C.subtype?(C.closed_map([{:x, C.integer(), false}], []), open_atoms.hi)
      refute C.subtype?(C.closed_map([], [{[:binary], C.integer()}]), open_atoms.hi)

      # %{String.t() => integer()} requires at least one key; the upper
      # bound admits the empty map, the lower bound does not.
      assert loss_kinds(strings.losses) == [:map_key_widened]
      assert C.subtype?(C.empty_map(), strings.hi)
      refute C.subtype?(C.empty_map(), strings.lo)
      assert C.subtype?(strings.lo, strings.hi)

      # struct(): literal __struct__ overlaps the atom() key domain; the
      # literal field takes precedence.
      assert struct.losses == []
      good = C.closed_map([{:__struct__, C.atom([Foo]), false}, {:x, C.integer(), false}], [])
      bad = C.closed_map([{:__struct__, C.integer(), false}], [])
      assert C.subtype?(good, struct.hi)
      refute C.subtype?(bad, struct.hi)

      assert_exact(
        ret,
        C.closed_map([{:a, C.integer(), false}, {:b, C.atom(), true}], [])
      )
    end

    test "literal map types are closed" do
      bound =
        raw(
          {:type, 0, :map,
           [{:type, 0, :map_field_exact, [{:atom, 0, :a}, {:type, 0, :integer, []}]}]}
        )

      assert bound.losses == []

      refute C.subtype?(
               C.closed_map([{:a, C.integer(), false}, {:b, C.atom(), false}], []),
               bound.hi
             )
    end

    test "non-whole-kind optional keys widen the upper bound only" do
      key = {:type, 0, :tuple, [{:type, 0, :atom, []}]}

      bound =
        raw({:type, 0, :map, [{:type, 0, :map_field_assoc, [key, {:type, 0, :integer, []}]}]})

      assert loss_kinds(bound.losses) == [:map_key_widened]
      assert C.equal?(bound.lo, C.empty_map())
      assert C.subtype?(C.closed_map([], [{[:tuple], C.integer()}]), bound.hi)
    end
  end

  describe "arrows" do
    test "exact arrows translate as fun(args, ret); returns stay covariant" do
      %{args: [arg], return: ret} = slice(Types, :exact_arrow, 1)
      assert_exact(arg, C.fun([C.integer()], C.atom()))

      assert C.equal?(ret.hi, C.fun([C.atom()], C.integer()))
      assert C.equal?(ret.lo, C.fun([C.atom()], C.none()))
      assert [%{kind: :integer_refinement_erased, path: [:return, :fun_return]}] = ret.losses
    end

    test "an inexact argument is not widened (contravariance)" do
      %{args: [arg], return: ret} = slice(Types, :inexact_arrow, 1)

      # (pos_integer() -> atom()): widening the argument to integer() would
      # NARROW the function set, so fun([integer()], atom()) is not an upper
      # bound of the spec. The translation must use fun(1).
      assert_bounds(arg, C.none(), C.fun(1), [:arrow_polarity])
      narrowed = C.fun([C.integer()], C.atom())
      assert C.subtype?(narrowed, arg.hi)
      refute C.subtype?(arg.hi, narrowed)

      # The same effect on an expressible refinement: the function type of
      # the precise argument (:a -> atom()) is NOT contained in the one of the
      # widened argument (atom() -> atom()), but is contained in fun(1).
      precise = C.fun([C.atom([:a])], C.atom())
      widened = C.fun([C.atom()], C.atom())
      refute C.subtype?(precise, widened)
      assert C.subtype?(precise, C.fun(1))

      assert_bounds(ret, C.none(), C.fun(), [:arrow_polarity])
    end
  end

  describe "named types" do
    test "remote type arguments are qualified in the caller's module" do
      %{args: [arg]} = slice(Types, :remote_qualified, 1)
      # local() is Types.local :: atom(), not Remote.local :: integer().
      assert_exact(arg, C.tuple([C.atom()]))
    end

    test "opaque types of other modules are boundaries" do
      %{args: [arg], return: ret} = slice(Types, :opaque_remote, 1)
      assert_bounds(arg, C.none(), C.term(), [:opaque_boundary])
      assert [%{path: [{:arg, 0}, {:type, Remote, :secret, 0}]}] = arg.losses
      # The module's own opaque type is transparent.
      assert_exact(ret, C.tuple([C.atom()]))
    end

    test "expand_opaque expands structurally and labels the expansion" do
      %{args: [arg]} = slice(Types, :opaque_remote, 1, expand_opaque: true)
      assert_exact(arg, C.tuple([C.integer()]))
      assert [%{kind: :opaque_expanded}] = arg.notes
    end

    test "nominal types of other modules are boundaries" do
      cache = TypeCache.new()
      body = {:type, 0, :integer, []}
      :ok = TypeCache.put_module(cache, NominalOwner, nil, {:ok, [nominal: {:id, body, []}]})
      ctx = Translate.context(Types, cache)
      ast = {:remote_type, 0, [{:atom, 0, NominalOwner}, {:atom, 0, :id}, []]}
      {:ok, bound} = Translate.type(ast, ctx)
      assert_bounds(bound, C.none(), C.term(), [:nominal_boundary])
    end

    test "unresolved remote types" do
      ast = {:remote_type, 0, [{:atom, 0, SpecLint.NoSuchModule}, {:atom, 0, :t}, []]}
      assert_bounds(raw(ast), C.none(), C.term(), [:unresolved_remote_type])
    end

    test "recursive types are cut off and never exact" do
      %{args: [arg], return: ret} = slice(Types, :recursive, 1)

      for bound <- [arg, ret] do
        refute Bound.exact?(bound)
        assert loss_kinds(bound.losses) == [:recursive_cutoff]
        assert C.subtype?(C.tuple([C.atom([:leaf]), C.integer()]), bound.hi)

        assert C.subtype?(
                 C.tuple([C.atom([:node]), C.tuple([C.atom([:leaf]), C.integer()]), C.term()]),
                 bound.hi
               )
      end
    end

    test "Elixir builtins resolve through :elixir" do
      ast =
        {:remote_type, 0, [{:atom, 0, :elixir}, {:atom, 0, :as_boolean}, [{:type, 0, :atom, []}]]}

      assert_exact(raw(ast), C.atom())
    end
  end

  describe "type variables" do
    test "a variable in the return and an argument is correlated" do
      %{args: [arg], return: ret} = slice(Types, :correlated, 1)
      assert_exact(arg, C.atom())
      assert_bounds(ret, C.none(), C.atom(), [:type_variable_correlation])
    end

    test "recursive constraints are cut off, not unsupported" do
      %{args: [arg], return: ret} = slice(List, :flatten, 1)
      assert loss_kinds(arg.losses) == [:recursive_cutoff]
      assert C.subtype?(C.list(C.list(C.integer())), arg.hi)
      assert_exact(ret, C.list(C.term()))
    end

    test "a variable repeated only among arguments is exact" do
      %{args: [a, b], return: ret} = slice(Types, :same_args, 2)
      assert_exact(a, C.atom())
      assert_exact(b, C.atom())
      assert_exact(ret, C.atom([:ok]))
    end
  end

  describe "unsupported constructs" do
    test "only the slice with the construct is unsupported" do
      bad =
        {:type, 0, :fun,
         [{:type, 0, :product, [{:type, 0, :weird_builtin, []}]}, {:atom, 0, :ok}]}

      good =
        {:type, 0, :fun, [{:type, 0, :product, [{:type, 0, :atom, []}]}, {:atom, 0, :ok}]}

      ctx = context(Types)
      assert {:unsupported, {:builtin, :weird_builtin, []}} = Translate.slice(bad, ctx)
      assert {:ok, %{args: [arg]}} = Translate.slice(good, ctx)
      assert_exact(arg, C.atom())
    end
  end
end
