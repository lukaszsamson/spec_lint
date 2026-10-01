defmodule SpecLintTest do
  use ExUnit.Case, async: true

  alias SpecLint.Fixtures

  setup_all do
    %{findings: findings, specs: specs} =
      SpecLint.run([Mix.Project.compile_path()], modules: [Fixtures])

    %{findings: findings, specs: specs, by_function: Enum.group_by(findings, & &1.function)}
  end

  test "every spec clause of the fixture module is compared", %{specs: specs} do
    assert specs == 20
  end

  test "a clause the compiler keeps but that can never match is not an error", %{by_function: by} do
    assert [%{severity: :warning, check: :clause_conflict}] = by[:dead_clause]
  end

  test "a return disjoint from the spec return is an error", %{by_function: by} do
    assert [%{severity: :error, check: :return_conflict, arity: 1} = f] = by[:return_conflict]
    assert f.message =~ "{:ok, term()} is disjoint"
    assert f.file == "test/support/fixtures.ex"
    assert is_integer(f.line)
    assert f.spec == ["@spec return_conflict(integer()) :: atom()"]
    assert f.inferred == [inferred("(term()) -> dynamic({:ok, term()})")]
  end

  test "a clause returning outside the spec is a warning", %{by_function: by} do
    assert [%{severity: :warning, check: :clause_conflict} = f] = by[:clause_conflict]
    assert f.message =~ "(#{inferred(":b")}) returns :error"
    # Catch-all positions are accepted only from 1.20 on, where the
    # compiler subtracts the earlier clauses from a clause's domain. On
    # 1.19 the catch-all after `caught(nil)` still looks reachable for nil
    # and its return is reported as a missing return.
    if Version.match?(System.version(), ">= 1.20.0") do
      assert by[:caught] == nil
      assert [%{check: :clause_conflict, message: m}] = by[:catch_all]
      assert m =~ "(:y, term()) returns :nope"
      assert [%{check: :clause_conflict, message: m}] = by[:shadowed]
      assert m =~ "(not nil) returns :b"
    else
      assert [%{check: :missing_return}] = by[:caught]
      assert [%{check: :missing_return}] = by[:catch_all]
      assert [%{check: :missing_return}] = by[:shadowed]
    end
  end

  # Elixir 1.19 infers no argument types from guards, so it rejects nothing.
  if Version.match?(System.version(), ">= 1.20.0") do
    test "a spec domain no clause accepts is an error", %{by_function: by} do
      assert [%{severity: :error, check: :domain_rejected}] = by[:domain_rejected]
    end
  end

  # Elixir 1.19 prints inferred argument types as dynamic(...).
  defp inferred(string) do
    if Version.match?(System.version(), ">= 1.20.0") do
      string
    else
      case string do
        "term()" -> "dynamic()"
        "(term()) -> " <> rest -> "(dynamic()) -> " <> rest
        other -> "dynamic(#{other})"
      end
    end
  end

  test "an undeclared tuple payload is a missing-return warning", %{by_function: by} do
    assert [%{severity: :warning, check: :missing_return} = f] = by[:missing_return]
    assert f.message =~ "{:error, :inactive}"
  end

  test "an undeclared atom and an undeclared struct are missing-return warnings", %{
    by_function: by
  } do
    assert [%{severity: :warning, check: :missing_return, message: m1}] = by[:missing_atom]
    assert m1 =~ ":empty"
    assert [%{severity: :warning, check: :missing_return, message: m2}] = by[:missing_struct]
    assert m2 =~ "Item"
  end

  test "a return under a no_return() spec is a warning", %{by_function: by} do
    assert [%{severity: :warning, check: :unexpected_return}] = by[:unexpected_return]
  end

  test "correct, gradual, wider and refined specs stay silent", %{by_function: by} do
    for function <- [
          :dynamic_no_return,
          :fine,
          :gradual_payload,
          :halts,
          :unknown,
          :wider_spec,
          :refined,
          :correlated,
          :user_type
        ] do
      assert by[function] == nil, "#{function} reported #{inspect(by[function])}"
    end
  end

  test "ignore entries match modules, functions, arities and regexes", %{findings: findings} do
    finding = Enum.find(findings, &(&1.function == :return_conflict))
    assert SpecLint.ignored?(finding, [Fixtures])
    assert SpecLint.ignored?(finding, [{Fixtures, :return_conflict}])
    assert SpecLint.ignored?(finding, [{Fixtures, :return_conflict, 1}])
    assert SpecLint.ignored?(finding, [~r/return_conflict\/1$/])

    refute SpecLint.ignored?(finding, [
             {Fixtures, :return_conflict, 2},
             {Fixtures, :other},
             ~r/^Other/
           ])

    assert %{findings: []} =
             SpecLint.run([Mix.Project.compile_path()], modules: [Fixtures], ignore: [Fixtures])
  end

  describe "typespec translation" do
    import Module.Types.Descr,
      only: [
        atom: 0,
        atom: 1,
        atom_fetch: 1,
        binary: 0,
        closed_map: 1,
        equal?: 2,
        integer: 0,
        list: 1,
        open_map: 0,
        subtype?: 2,
        term: 0,
        tuple: 1
      ]

    import SpecLint.Descr

    defp translate(string) do
      {:ok, ast} = Code.string_to_quoted(string)
      spec = {:type, 0, :fun, [{:type, 0, :product, []}, ast]}
      # Round-trip through the typespec API so the AST has the BEAM shape.
      {:ok, [], translated} = SpecLint.Typespec.spec(from_quoted(spec, ast), Fixtures)
      translated
    end

    defp from_quoted(_spec, ast) do
      {:type, 0, :fun, [{:type, 0, :product, []}, to_erl(ast)]}
    end

    defp to_erl({:|, _, [a, b]}), do: {:type, 0, :union, [to_erl(a), to_erl(b)]}

    defp to_erl([{:->, _, [args, ret]}]),
      do: {:type, 0, :fun, [{:type, 0, :product, Enum.map(args, &to_erl/1)}, to_erl(ret)]}

    defp to_erl({:{}, _, elems}), do: {:type, 0, :tuple, Enum.map(elems, &to_erl/1)}
    defp to_erl({a, b}), do: {:type, 0, :tuple, [to_erl(a), to_erl(b)]}
    defp to_erl([elem]), do: {:type, 0, :list, [to_erl(elem)]}

    defp to_erl({:%{}, _, pairs}),
      do:
        {:type, 0, :map,
         Enum.map(pairs, fn {k, v} -> {:type, 0, :map_field_exact, [to_erl(k), to_erl(v)]} end)}

    defp to_erl({{:., _, [mod, name]}, _, args}),
      do:
        {:remote_type, 0,
         [{:atom, 0, Macro.expand(mod, __ENV__)}, {:atom, 0, name}, Enum.map(args, &to_erl/1)]}

    defp to_erl({name, _, args}) when is_atom(name) and is_list(args),
      do: {:type, 0, name, Enum.map(args, &to_erl/1)}

    defp to_erl({name, _, nil}), do: {:var, 0, name}
    defp to_erl(atom) when is_atom(atom), do: {:atom, 0, atom}
    defp to_erl(int) when is_integer(int), do: {:integer, 0, int}

    test "exact translations" do
      assert {descr, true} = translate(":ok | {:error, binary()} | [integer()]")

      assert equal?(
               descr,
               union(atom([:ok]), union(tuple([atom([:error]), binary()]), list(integer())))
             )

      assert {descr, true} = translate("%{a: integer()}")
      assert equal?(descr, closed_map(a: field(integer(), false)))
      assert {descr, exact?} = translate("(integer() -> atom())")
      assert {expected, ^exact?} = fun_type([integer()], atom(), true)
      assert equal?(descr, expected)
    end

    test "inexact translations over-approximate" do
      assert {descr, false} = translate("pos_integer()")
      assert equal?(descr, integer())
      assert {descr, false} = translate("(pos_integer() -> atom())")
      assert equal?(descr, fun_of_arity(1))
      assert {descr, false} = translate("x")
      assert equal?(descr, term())
    end

    test "user and remote types expand" do
      assert {descr, true} = translate("SpecLint.Fixtures.Item.t()")
      assert subtype?(descr, open_map())

      assert {:finite, [SpecLint.Fixtures.Item]} =
               descr |> map_fetch_key(:__struct__) |> elem(1) |> atom_fetch()
    end

    test "unknown types are any term, inexact" do
      spec = {:type, 0, :fun, [{:type, 0, :product, []}, {:user_type, 0, :nope, []}]}
      assert {:ok, [], {descr, false}} = SpecLint.Typespec.spec(spec, Fixtures)
      assert equal?(descr, term())
    end

    test "unsupported constructs are reported with a reason" do
      constraint =
        {:type, 0, :constraint, [{:atom, 0, :is_weird}, [{:var, 0, :x}, {:type, 0, :atom, []}]]}

      fun = {:type, 0, :fun, [{:type, 0, :product, [{:var, 0, :x}]}, {:var, 0, :x}]}

      assert {:error, {:type, 0, :constraint, _}} =
               SpecLint.Typespec.spec({:type, 0, :bounded_fun, [fun, [constraint]]}, Fixtures)
    end
  end
end
