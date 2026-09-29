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

    test "integer refinements keep the intervals they denote" do
      %{args: args, return: ret} = slice(Types, :refined, 5)

      assert Enum.map(args, & &1.integers) == [
               [{1, :infinity}],
               [{0, :infinity}],
               [{1, 10}],
               [{-1, -1}],
               [{0, 255}]
             ]

      assert ret.integers == [{0, 0x10FFFF}]

      union = raw({:type, 0, :union, [{:integer, 0, 0}, {:type, 0, :atom, []}]})
      assert union.integers == [{0, 0}]
      assert Bound.integer_intervals(union) == [{0, 0}]

      mixed = raw({:type, 0, :union, [{:integer, 0, 0}, {:type, 0, :integer, []}]})
      assert Bound.integer_intervals(mixed) == [{0, 0}, {:neg_infinity, :infinity}]

      assert raw({:op, 0, :+, {:integer, 0, 1}, {:integer, 0, 2}}).integers == [{3, 3}]
      assert raw({:type, 0, :integer, []}).integers == nil
      assert Bound.integer_intervals(raw({:type, 0, :atom, []})) == []
    end

    test "interval disjointness" do
      assert Bound.intervals_disjoint?([{0, 0}], [{1, :infinity}])
      assert Bound.intervals_disjoint?([{:neg_infinity, -1}], [{0, :infinity}])
      refute Bound.intervals_disjoint?([{0, 5}], [{5, 7}])
      refute Bound.intervals_disjoint?([{:neg_infinity, :infinity}], [{3, 3}])
      assert Bound.intervals_disjoint?([], [{:neg_infinity, :infinity}])
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

    test "a key mixing finite atoms with another kind keeps the atoms in hi" do
      %{args: [optional, required]} = slice(Types, :map_mixed, 2)
      a_atom = C.closed_map([{:a, C.atom([:x]), false}], [])
      ints = C.closed_map([], [{[:integer], C.atom()}])

      # %{optional(:a | integer()) => atom()} is exact: :a is a field, the
      # integers a whole-kind domain.
      assert optional.losses == []
      assert C.subtype?(a_atom, optional.hi)
      assert C.subtype?(ints, optional.hi)
      assert C.subtype?(C.empty_map(), optional.lo)
      refute C.subtype?(C.closed_map([{:a, C.integer(), false}], []), optional.hi)

      assert loss_kinds(required.losses) == [:map_key_widened]
      assert C.subtype?(a_atom, required.hi)
      assert C.subtype?(ints, required.hi)
      assert C.empty?(required.lo)
    end

    test "overlapping finite atom keys: the first association wins" do
      %{args: [arg]} = slice(Types, :map_shared_atoms, 1)
      # %{optional(:a | :b) => integer(), optional(:b | :c) => atom()}
      assert_exact(
        arg,
        C.closed_map(
          [{:a, C.integer(), true}, {:b, C.integer(), true}, {:c, C.atom(), true}],
          []
        )
      )
    end

    test "a required literal key after optional(atom()) is shadowed, not exact" do
      %{args: [arg]} = slice(Types, :map_shadowed, 1)

      # %{optional(atom()) => binary(), name: integer()}: Elixir emits keyword
      # keys last. Dialyzer reads %{atom() => binary()} (requirement dropped,
      # first value wins); the author may mean a required integer :name.
      # hi covers both readings, lo is inside both.
      hi =
        C.closed_map([{:name, C.union(C.binary(), C.integer()), true}], [{[:atom], C.binary()}])

      lo = C.closed_map([{:name, C.none(), false}], [{[:atom], C.binary()}])
      assert_bounds(arg, lo, hi, [:map_key_widened])
      assert [%{path: [{:arg, 0}, {:map_value, :name}]}] = arg.losses
      assert C.subtype?(C.closed_map([{:name, C.binary(), false}], []), arg.hi)
      assert C.subtype?(C.closed_map([{:name, C.integer(), false}], []), arg.hi)
      assert C.subtype?(C.empty_map(), arg.hi)
      refute C.subtype?(C.empty_map(), arg.lo)
    end

    test "a map with required keys after optional(any()) requires them in lo" do
      # Calendar.date(): %{optional(any) => any, calendar: ..., year: ...}.
      form =
        {:type, 0, :map,
         [
           {:type, 0, :map_field_assoc, [{:type, 0, :any, []}, {:type, 0, :any, []}]},
           {:type, 0, :map_field_exact, [{:atom, 0, :year}, {:type, 0, :integer, []}]}
         ]}

      bound = raw(form)
      assert loss_kinds(bound.losses) == [:map_key_widened]
      assert C.equal?(bound.hi, C.open_map())
      year = fn value -> C.closed_map([{:year, value, false}], []) end
      assert C.subtype?(year.(C.integer()), bound.lo)
      refute C.subtype?(year.(C.binary()), bound.lo)
      refute C.subtype?(C.empty_map(), bound.lo)
      refute C.subtype?(C.closed_map([{:month, C.integer(), false}], []), bound.lo)
      other = C.closed_map([{:year, C.integer(), false}, {:month, C.binary(), false}], [])
      assert C.subtype?(other, bound.lo)
    end

    test "a shadowed optional literal key stays exact" do
      form =
        {:type, 0, :map,
         [
           {:type, 0, :map_field_assoc, [{:type, 0, :atom, []}, {:type, 0, :binary, []}]},
           {:type, 0, :map_field_assoc, [{:atom, 0, :name}, {:type, 0, :integer, []}]}
         ]}

      assert_exact(raw(form), C.closed_map([], [{[:atom], C.binary()}]))
    end

    test "a required literal key before optional(atom()) is exact and required" do
      form =
        {:type, 0, :map,
         [
           {:type, 0, :map_field_exact, [{:atom, 0, :a}, {:type, 0, :atom, []}]},
           {:type, 0, :map_field_assoc, [{:type, 0, :atom, []}, {:type, 0, :integer, []}]}
         ]}

      assert_exact(raw(form), C.closed_map([{:a, C.atom(), false}], [{[:atom], C.integer()}]))
    end

    test "an inexact key keeps its finite atoms and kinds in hi only" do
      %{args: [single, overlapping]} = slice(Types, :map_inexact_key, 2)
      infinity = fn value -> C.closed_map([{:infinity, value, false}], []) end

      # optional(timeout()): integer refinement erased on the key.
      assert loss_kinds(single.losses) == [:integer_refinement_erased, :map_key_widened]
      assert C.subtype?(infinity.(C.atom()), single.hi)
      assert C.subtype?(C.closed_map([], [{[:integer], C.atom()}]), single.hi)
      assert C.equal?(single.lo, C.empty_map())

      # A later optional(:infinity) may apply where the inexact key does
      # not reach, so the upper bound joins both values.
      assert C.subtype?(infinity.(C.atom()), overlapping.hi)
      assert C.subtype?(infinity.(C.binary()), overlapping.hi)
      assert C.empty?(overlapping.lo)
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

  describe "map associations against Dialyzer's reading (erl_types)" do
    # Differential test: membership of witness maps in the translated bounds
    # against :erl_types on the same forms. Forms with at most one
    # non-singleton key domain only, because Dialyzer merges all key domains
    # into one default key and value, which is coarser than Descr.
    defp t(name), do: {:type, 0, name, []}
    defp a(atom), do: {:atom, 0, atom}
    defp u(types), do: {:type, 0, :union, types}
    defp opt(key, value), do: {:type, 0, :map_field_assoc, [key, value]}
    defp req(key, value), do: {:type, 0, :map_field_exact, [key, value]}
    defp map_form(assocs), do: {:type, 0, :map, assocs}

    defp dialyzer(form),
      do: :erl_types.t_from_form_without_remote(form, {:type, {Types, :t, 0}, ~c"nofile"}, %{})

    test "witness membership agrees" do
      forms = [
        map_form([opt(t(:atom), t(:binary)), req(a(:name), t(:integer))]),
        map_form([req(a(:name), t(:integer)), opt(t(:atom), t(:binary))]),
        map_form([opt(u([a(:a), a(:b)]), t(:integer)), opt(u([a(:b), a(:c)]), t(:atom))]),
        map_form([opt(u([a(:a), t(:integer)]), t(:atom))]),
        map_form([req(u([a(:a), t(:integer)]), t(:atom))]),
        map_form([req(a(:a), t(:integer)), req(a(:a), t(:atom))]),
        map_form([opt(u([a(:a), a(:b)]), t(:integer)), req(a(:a), t(:atom))]),
        map_form([opt(t(:atom), t(:integer)), opt(t(:atom), t(:binary))]),
        map_form([opt(t(:integer), t(:atom)), opt(a(:a), t(:binary))]),
        map_form([opt(t(:timeout), t(:atom)), opt(a(:infinity), t(:binary))])
      ]

      field_witnesses =
        for key <- [:a, :b, :c, :name, :infinity, :x],
            value <- [:integer, :atom, :binary],
            do: map_form([req(a(key), t(value))])

      witnesses =
        field_witnesses ++
          [
            map_form([]),
            map_form([req(a(:a), t(:integer)), req(a(:b), t(:integer))]),
            map_form([opt(t(:integer), t(:atom))]),
            map_form([opt(t(:atom), t(:binary))])
          ]

      for form <- forms, witness <- witnesses do
        bound = raw(form)
        w = raw(witness)
        assert w.losses == []
        in_dialyzer? = :erl_types.t_is_subtype(dialyzer(witness), dialyzer(form))
        label = "#{inspect(witness)} in #{inspect(form)}"

        if in_dialyzer?, do: assert(C.subtype?(w.hi, bound.hi), "hi misses " <> label)
        if C.subtype?(w.hi, bound.lo), do: assert(in_dialyzer?, "lo has extra " <> label)

        if Bound.exact?(bound),
          do: assert(C.subtype?(w.hi, bound.hi) == in_dialyzer?, "exact differs " <> label)
      end
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
      assert_bounds(arg, C.none(), C.fun(1), [:arrow_polarity, :integer_refinement_erased])
      assert %{kind: :arrow_polarity, path: [{:arg, 0}]} = hd(arg.losses)
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

    # Audit row 18 (Milestone 3): 1.21's Code.Typespec reports an Erlang
    # -nominal type as :nominal; 1.20.4's leaves it out, so a reference to
    # it is unresolved. Both give term() above and none() below.
    @tag :tmp_dir
    test "an Erlang nominal type read from its BEAM, per adapter", %{tmp_dir: dir} do
      module = :"spec_lint_nominal_#{System.unique_integer([:positive])}"

      forms = [
        {:attribute, 1, :module, module},
        {:attribute, 1, :export_type, [id: 0]},
        {:attribute, 1, :nominal, {:id, {:type, 1, :integer, []}, []}}
      ]

      {:ok, ^module, binary} = :compile.forms(forms, [:binary, :debug_info])
      File.write!(Path.join(dir, "#{module}.beam"), binary)
      true = Code.prepend_path(dir)

      try do
        ctx = Translate.context(Types, TypeCache.new())
        ast = {:remote_type, 0, [{:atom, 0, module}, {:atom, 0, :id}, []]}
        {:ok, bound} = Translate.type(ast, ctx)

        loss =
          if adapter().nominal_types?(), do: :nominal_boundary, else: :unresolved_remote_type

        assert_bounds(bound, C.none(), C.term(), [loss])
      after
        Code.delete_path(dir)
      end
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

    test "annotation names are not type variables" do
      %{args: [arg], return: ret} = slice(Types, :annotated, 1)
      assert_exact(arg, C.atom())
      assert_exact(ret, C.atom())
    end

    test "a variable reaching the return through `when` constraints is correlated" do
      # f(x) :: y when x: [a], y: a -- same as f([a]) :: a.
      %{args: [arg], return: ret} = slice(Types, :indirect, 1)
      assert_exact(arg, C.list(C.term()))
      assert_bounds(ret, C.none(), C.term(), [:type_variable_correlation])

      # f(a) :: b when b: [a], a: atom()
      %{args: [arg], return: ret} = slice(Types, :via_constraint, 1)
      assert_exact(arg, C.atom())
      assert_bounds(ret, C.none(), C.list(C.atom()), [:type_variable_correlation])
    end

    test "a variable inside an arrow argument falls back to fun(arity)" do
      # reduce_like([a], (a -> term())) when a: var. Instantiating a with
      # integer() gives (integer() -> term()), which must be inside hi.
      %{args: [list, callback]} = slice(Types, :reduce_like, 2)
      assert_exact(list, C.list(C.term()))
      assert_bounds(callback, C.none(), C.fun(1), [:arrow_polarity, :type_variable_correlation])
      assert %{kind: :arrow_polarity, path: [{:arg, 1}]} = hd(callback.losses)
      assert C.subtype?(C.fun([C.integer()], C.integer()), callback.hi)
      assert C.subtype?(C.fun([C.integer()], C.term()), callback.hi)

      # acc_fun((integer(), acc -> acc)) when acc: var
      %{args: [acc]} = slice(Types, :acc_fun, 1)
      assert C.equal?(acc.hi, C.fun(2))
      assert C.subtype?(C.fun([C.integer(), C.integer()], C.integer()), acc.hi)
      assert C.subtype?(C.fun([C.integer(), C.atom()], C.atom()), acc.hi)
    end

    test "a variable inside an arrow argument in the return" do
      # make_id() :: (a -> a) when a: var
      %{return: ret} = slice(Types, :make_id, 0)
      assert C.empty?(ret.lo)
      assert :arrow_polarity in loss_kinds(ret.losses)
      assert :type_variable_correlation in loss_kinds(ret.losses)
      assert C.subtype?(C.fun([C.integer()], C.integer()), ret.hi)
    end

    test "nested arrows and covariant arrow returns" do
      # (integer() -> a) with a: atom() elsewhere in the arguments: the
      # variable is covariant everywhere, the instance at the bound is the
      # largest.
      %{args: [callback, atom]} = slice(Types, :covariant_arrow, 2)
      assert_exact(callback, C.fun([C.integer()], C.atom()))
      assert_exact(atom, C.atom())

      # ((a -> term()) -> term()): any variable under an arrow argument makes
      # that arrow inexact, at any nesting.
      %{args: [nested, _]} = slice(Types, :nested_arrow, 2)
      assert C.equal?(nested.hi, C.fun(1))
      instance = C.fun([C.fun([C.atom([:x])], C.term())], C.term())
      assert C.subtype?(instance, nested.hi)
    end

    test "stdlib callbacks: List.foldl/3" do
      # foldl([elem], acc, (elem, acc -> acc))
      %{args: [_list, _acc, fun], return: ret} = slice(List, :foldl, 3)
      assert C.subtype?(C.fun([C.integer(), C.integer()], C.integer()), fun.hi)
      assert :arrow_polarity in loss_kinds(fun.losses)
      assert C.empty?(ret.lo)
    end

    test "a variable repeated only among covariant argument positions is exact" do
      %{args: [a, b], return: ret} = slice(Types, :same_args, 2)
      assert_exact(a, C.atom())
      assert_exact(b, C.atom())
      assert_exact(ret, C.atom([:ok]))
    end
  end

  describe "adapter key kinds" do
    test "a finite atom component counts as the atom kind" do
      assert C.key_kinds(C.union(C.atom([:a]), C.integer())) == [:atom, :integer]
      assert C.key_kinds(C.atom([:a, :b])) == [:atom]
      assert C.key_kinds(C.integer()) == [:integer]
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

    test "argument bounds of an unsupported slice, one position at a time" do
      ctx = context(Types)

      bad =
        {:type, 0, :fun,
         [
           {:type, 0, :product, [{:type, 0, :weird_builtin, []}, {:type, 0, :atom, []}]},
           {:type, 0, :weird_builtin, []}
         ]}

      assert {:unsupported, _} = Translate.slice(bad, ctx)
      assert {:ok, [unknown, atom]} = Translate.argument_bounds(bad, ctx)
      assert C.equal?(unknown.hi, C.term())
      assert C.empty?(unknown.lo)
      assert loss_kinds(unknown.losses) == [:unsupported_construct]
      assert_exact(atom, C.atom())

      # Not a function type: no argument list to translate.
      assert Translate.argument_bounds({:type, 0, :weird_builtin, []}, ctx) == :error
    end
  end
end
