defmodule SpecLint do
  @moduledoc """
  Compares `@spec` declarations with the signatures the Elixir compiler
  infers for the same functions.

  The compiler stores an inferred signature for every function in the
  `ExCk` chunk of the BEAM file. SpecLint translates each spec clause into
  the compiler's types (`SpecLint.Typespec`), applies the inferred
  signature to the spec's argument types with the compiler's own rule
  (`apply_infer/2`), and compares the returns:

    * `return_conflict` (error): the inferred return is disjoint from the
      spec return, so no value the function returns satisfies the spec;
    * `domain_rejected` (error): no inferred clause accepts the spec's
      arguments, so the compiler would warn on every conforming call;
    * `clause_conflict` (warning): a clause that accepts only
      spec-conforming arguments returns a value disjoint from the spec
      return. A warning, not an error: the compiler keeps clauses that can
      never match (`def f(:b = x) when is_integer(x)`), so a stored clause
      is not proof of reachable behaviour;
    * `missing_return` (warning): the inferred return has a literal shape
      the spec does not declare, such as an `{:error, _}` tuple, an atom
      or a struct the spec never mentions;
    * `unexpected_return` (warning): the spec says `no_return()` and the
      compiler infers a concrete return.

  Nothing else is reported: inference is deliberately conservative, so an
  inferred type wider than the spec is normal and silent.
  """

  import Module.Types.Descr,
    only: [
      atom: 0,
      atom: 1,
      atom_fetch: 1,
      disjoint?: 2,
      dynamic: 0,
      dynamic: 1,
      list: 1,
      empty?: 1,
      map_fetch_key: 2,
      non_empty_list: 2,
      open_map: 0,
      subtype?: 2,
      term: 0,
      to_quoted_string: 1,
      tuple: 1,
      tuple_fetch: 2,
      upper_bound: 1
    ]

  import SpecLint.Descr

  alias SpecLint.Typespec

  @max_clauses 16
  @max_tuple 12

  @typedoc "One reported problem."
  @type finding :: %{
          severity: :error | :warning,
          check: atom(),
          module: module(),
          function: atom(),
          arity: arity(),
          file: String.t() | nil,
          line: pos_integer() | nil,
          message: String.t(),
          spec: [String.t()],
          inferred: [String.t()]
        }

  @typedoc """
  An ignore entry: a module, a `{module, function}` pair, a
  `{module, function, arity}` triple, or a regex matched against
  `"Module.function/arity"`.
  """
  @type ignore :: module() | {module(), atom()} | {module(), atom(), arity()} | Regex.t()

  @doc """
  Analyses every `Elixir.*.beam` file in the `ebins` directories.

  Options: `:ignore`, a list of `t:ignore/0` entries whose findings are
  dropped; `:modules`, a list of modules to restrict the analysis to.
  Returns the findings, the number of spec clauses compared and the spec
  clauses skipped because a type could not be translated, with the reason.
  """
  @spec run([Path.t()], keyword()) :: %{
          findings: [finding()],
          specs: non_neg_integer(),
          skipped: [{module(), atom(), arity(), term()}]
        }
  def run(ebins, opts \\ []) do
    Enum.each(ebins, &Code.prepend_path/1)
    ignore = Keyword.get(opts, :ignore, [])
    only = Keyword.get(opts, :modules)

    ebins
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "Elixir.*.beam")))
    |> Enum.sort()
    |> Enum.map(&module(&1, only))
    |> Enum.reduce(%{findings: [], specs: 0, skipped: []}, fn {findings, specs, skipped}, acc ->
      %{
        findings: acc.findings ++ findings,
        specs: acc.specs + specs,
        skipped: acc.skipped ++ skipped
      }
    end)
    |> Map.update!(:findings, fn findings -> Enum.reject(findings, &ignored?(&1, ignore)) end)
  end

  @doc "Whether `finding` matches one of the `ignore` entries."
  @spec ignored?(finding(), [ignore()]) :: boolean()
  def ignored?(finding, ignore) do
    Enum.any?(ignore, fn
      module when is_atom(module) -> finding.module == module
      {module, function} -> finding.module == module and finding.function == function
      {m, f, a} -> finding.module == m and finding.function == f and finding.arity == a
      %Regex{} = regex -> Regex.match?(regex, mfa(finding))
    end)
  end

  @doc "`\"Module.function/arity\"` of a finding."
  @spec mfa(finding()) :: String.t()
  def mfa(finding), do: "#{inspect(finding.module)}.#{finding.function}/#{finding.arity}"

  defp module(path, only) do
    binary = File.read!(path)

    with {:ok, {module, chunks}} <-
           :beam_lib.chunks(binary, [:exports, ~c"ExCk", :debug_info], [:allow_missing_chunks]),
         true <- only == nil or module in only,
         {~c"ExCk", exck} when is_binary(exck) <- List.keyfind(chunks, ~c"ExCk", 0),
         {:ok, specs} <- Code.Typespec.fetch_specs(binary) do
      signatures = signatures(exck)
      {file, lines} = locations(chunks[:debug_info], module)
      exports = chunks[:exports]

      specs
      |> Enum.filter(fn {fa, _clauses} -> fa in exports and is_map_key(signatures, fa) end)
      |> Enum.sort()
      |> Enum.map(fn {{name, arity}, clauses} ->
        base = %{
          module: module,
          function: name,
          arity: arity,
          file: file,
          line: lines[{name, arity}],
          spec_clauses: clauses,
          inferred_clauses: signatures[{name, arity}]
        }

        function(base, clauses, signatures[{name, arity}])
      end)
      |> Enum.reduce({[], 0, []}, fn {findings, specs, skipped}, {acc, n, skipped_acc} ->
        {acc ++ findings, n + specs, skipped_acc ++ skipped}
      end)
    else
      _ -> {[], 0, []}
    end
  end

  # The ExCk chunk: `{version, %{exports: [{{name, arity}, %{sig: signature}}]}}`
  # where an inferred signature is `{:infer, domain, [{arg_types, return}]}`.
  defp signatures(exck) do
    {_version, %{exports: exports}} = :erlang.binary_to_term(exck)

    for {fa, %{sig: {:infer, _domain, [_ | _] = clauses}}} <- exports,
        into: %{},
        do: {fa, clauses}
  end

  defp locations({:debug_info_v1, backend, data}, module) do
    case backend.debug_info(:elixir_v1, module, data, []) do
      {:ok, %{definitions: definitions, file: file}} ->
        lines = for {fa, _kind, meta, _clauses} <- definitions, into: %{}, do: {fa, meta[:line]}
        {Path.relative_to_cwd(file), lines}

      _ ->
        {nil, %{}}
    end
  end

  defp locations(_missing, _module), do: {nil, %{}}

  defp function(base, clauses, inferred) do
    Enum.reduce(clauses, {[], 0, []}, fn clause, {findings, n, skipped} ->
      case Typespec.spec(clause, base.module) do
        {:ok, args, return} ->
          {findings ++ slice(base, args, return, inferred), n + 1, skipped}

        {:error, reason} ->
          {findings, n, skipped ++ [{base.module, base.function, base.arity, reason}]}
      end
    end)
  end

  defp slice(base, args, {spec_return, _exact}, inferred) do
    arg_types = Enum.map(args, &elem(&1, 0))
    args_exact? = Enum.all?(args, &elem(&1, 1))

    case apply_infer(inferred, arg_types) do
      :error ->
        if Enum.all?(arg_types, &(not empty?(&1))),
          do: [
            finding(
              base,
              :error,
              :domain_rejected,
              "no inferred clause accepts the arguments of this spec clause"
            )
          ],
          else: []

      {_used, applied} ->
        returns(base, inferred, arg_types, args_exact?, upper_bound(applied), spec_return)
    end
  end

  defp returns(base, inferred, arg_types, args_exact?, applied, spec_return) do
    cond do
      empty?(spec_return) ->
        unexpected_return(base, applied)

      empty?(applied) ->
        []

      disjoint?(applied, spec_return) ->
        [
          finding(
            base,
            :error,
            :return_conflict,
            "inferred return #{str(applied)} is disjoint from the spec return " <>
              str(spec_return)
          )
        ]

      true ->
        case clause_conflicts(base, inferred, arg_types, spec_return, args_exact?) do
          [] -> missing_returns(base, inferred, arg_types, spec_return)
          conflicts -> conflicts
        end
    end
  end

  defp unexpected_return(base, applied) do
    if empty?(applied) or near_top?(applied),
      do: [],
      else: [
        finding(
          base,
          :warning,
          :unexpected_return,
          "declared no_return(), inferred return #{str(applied)}"
        )
      ]
  end

  # The inferred clauses whose domains meet the spec domain, in order.
  defp contributing(inferred, arg_types),
    do:
      Enum.filter(inferred, fn {clause_args, _} -> zip_not_disjoint?(arg_types, clause_args) end)

  # A clause that returns outside the spec return for some spec-conforming
  # input is a conflict. Inference over-approximates a clause's domain (a
  # guard such as `is_map_key(x, :a)` leaves `map()`), so a domain that
  # merely overlaps the spec might accept none of its values. The clause
  # is known to accept a spec value at a position when its domain there is
  # inside the spec type, or is a catch-all (`term()` minus the literals of
  # the earlier clauses, which the compiler already subtracts) that meets
  # the spec type. Requires exactly translated arguments.
  defp clause_conflicts(_base, _inferred, _arg_types, _spec_return, false), do: []

  defp clause_conflicts(base, inferred, arg_types, spec_return, true) do
    for {clause_args, clause_return} <- inferred,
        Enum.zip(clause_args, arg_types)
        |> Enum.all?(fn {c, s} ->
          c = upper_bound(c)
          subtype?(c, s) or (near_top?(c) and not disjoint?(c, s))
        end),
        return = upper_bound(clause_return),
        not empty?(return),
        disjoint?(return, spec_return) do
      finding(
        base,
        :warning,
        :clause_conflict,
        "the clause accepting (#{Enum.map_join(clause_args, ", ", &str/1)}) returns " <>
          "#{str(return)}, disjoint from the spec return #{str(spec_return)}"
      )
    end
  end

  # Each contributing clause's return, minus the spec return, is reported
  # when it holds a literal shape the spec never declares: a finite atom,
  # a tuple of a size or tag the spec lacks, a struct the spec lacks, or,
  # under a declared tuple tag, such a literal in the payload. Clauses are
  # compared one at a time so that a clause returning `{:ok, term()}` does
  # not hide another returning `{:ok, :ok}`. A clause whose return is near
  # the top type (`dynamic()`, "anything but a few values") says nothing.
  # A whole kind (every integer, every binary, ...) counts only when the
  # clause accepts nothing outside the spec domain: inference does not
  # specialise a clause's return to the arguments, so `x + 1` returns
  # `integer() or float()` for any number and the float is noise unless
  # the clause takes numbers only where the spec allows them.
  defp missing_returns(base, inferred, arg_types, spec_return) do
    extras =
      for {clause_args, clause_return} <- contributing(inferred, arg_types),
          return = upper_bound(clause_return),
          not near_top?(return),
          extra = difference(return, spec_return),
          not empty?(extra),
          escape?(extra, spec_return, contained?(clause_args, arg_types), 2),
          do: extra

    case extras do
      [] ->
        []

      extras ->
        extra = Enum.reduce(extras, &union/2)

        [
          finding(
            base,
            :warning,
            :missing_return,
            "inferred return includes #{str(extra)}, which the spec does not declare"
          )
        ]
    end
  end

  # Whether a clause accepts nothing outside the spec domain.
  defp contained?(clause_args, arg_types) do
    Enum.zip(clause_args, arg_types)
    |> Enum.all?(fn {c, s} -> subtype?(upper_bound(c), s) end)
  end

  # A type that holds most whole kinds is "anything but a few values"
  # (a fall-through `other -> other`, a truthy value, a gradual payload):
  # it carries no literal shape and is never compared.
  @whole_kinds [
    :atom,
    :integer,
    :float,
    :bitstring,
    :pid,
    :port,
    :reference,
    :fun,
    :list,
    :open_map,
    :tuple
  ]

  defp near_top?(descr) do
    Enum.count(@whole_kinds, fn kind -> subtype?(kind(kind), descr) end) >= 6
  end

  defp escape?(extra, spec, kinds?, depth) do
    not near_top?(union(extra, spec)) and
      ((kinds? and kind_escape?(extra, spec)) or atom_escape?(extra) or
         tuple_escape?(extra, spec, kinds?, depth) or map_escape?(extra, spec, kinds?))
  end

  @kinds [
    :integer,
    :float,
    :binary,
    :bitstring_no_binary,
    :pid,
    :port,
    :reference,
    :fun,
    :empty_list,
    :non_empty_list,
    :open_map
  ]

  defp kind_escape?(extra, spec) do
    Enum.any?(@kinds, fn kind ->
      kind = kind(kind)
      not empty?(intersection(extra, kind)) and empty?(intersection(spec, kind))
    end)
  end

  defp kind(:non_empty_list), do: non_empty_list(term(), term())
  defp kind(:list), do: list(term())
  defp kind(name), do: apply(Module.Types.Descr, name, [])

  defp atom_escape?(extra) do
    atoms = intersection(extra, atom())
    not empty?(atoms) and match?({:finite, _}, atom_fetch(atoms))
  end

  defp tuple_escape?(extra, spec, kinds?, depth) do
    Enum.any?(0..@max_tuple, fn size ->
      shape = tuple(List.duplicate(term(), size))
      extra_tuples = intersection(extra, shape)

      cond do
        empty?(extra_tuples) -> false
        empty?(intersection(spec, shape)) -> true
        size == 0 -> false
        true -> tag_escape?(extra_tuples, intersection(spec, shape), size, kinds?, depth)
      end
    end)
  end

  defp tag_escape?(extra_tuples, spec_tuples, size, kinds?, depth) do
    with {_optional?, first} <- tuple_fetch(extra_tuples, 0),
         {:finite, tags} <- atom_fetch(intersection(first, atom())) do
      Enum.any?(tags, fn tag ->
        tagged = tuple([atom([tag]) | List.duplicate(term(), size - 1)])
        spec_tagged = intersection(spec_tuples, tagged)

        extra_tagged = intersection(extra_tuples, tagged)

        empty?(spec_tagged) or
          (depth > 0 and payload_escape?(extra_tagged, spec_tagged, size, kinds?, depth))
      end)
    else
      _ -> false
    end
  end

  defp payload_escape?(extra_tagged, spec_tagged, size, kinds?, depth) do
    Enum.any?(1..(size - 1)//1, fn index ->
      with {_, extra_element} <- tuple_fetch(extra_tagged, index),
           {_, spec_element} <- tuple_fetch(spec_tagged, index) do
        difference = difference(extra_element, spec_element)
        not empty?(difference) and escape?(difference, spec_element, kinds?, depth - 1)
      else
        _ -> false
      end
    end)
  end

  defp map_escape?(extra, spec, kinds?) do
    extra_maps = intersection(extra, open_map())
    spec_maps = intersection(spec, open_map())

    cond do
      empty?(extra_maps) -> false
      empty?(spec_maps) -> kinds? or match?({:finite, [_ | _]}, struct_names(extra_maps))
      true -> struct_escape?(extra_maps, spec_maps)
    end
  end

  defp struct_escape?(extra_maps, spec_maps) do
    with {:finite, names} <- struct_names(extra_maps),
         {:finite, spec_names} <- struct_names(spec_maps) do
      Enum.any?(names, &(&1 not in spec_names))
    else
      _ -> false
    end
  end

  defp struct_names(maps) do
    case map_fetch_key(maps, :__struct__) do
      {_optional?, names} -> atom_fetch(intersection(names, atom()))
      _ -> :error
    end
  end

  # Copy of the private Module.Types.Apply.apply_infer/2 (Elixir 1.20):
  # every clause whose argument types are positionwise non-disjoint from
  # the given types contributes its return; the union is gradual.
  defp apply_infer(clauses, args_types) do
    case apply_clauses(clauses, args_types, 0, [], []) do
      {0, [], []} -> :error
      {count, used, _returns} when count > @max_clauses -> {used, dynamic()}
      {_count, used, returns} -> {used, returns |> Enum.reduce(&union/2) |> dynamic()}
    end
  end

  defp apply_clauses([{expected, return} = clause | clauses], args_types, count, used, returns) do
    if zip_not_disjoint?(args_types, expected),
      do: apply_clauses(clauses, args_types, count + 1, [clause | used], [return | returns]),
      else: apply_clauses(clauses, args_types, count, used, returns)
  end

  defp apply_clauses([], _args_types, count, used, returns), do: {count, used, returns}

  defp zip_not_disjoint?([actual | actuals], [expected | expecteds]),
    do: not disjoint?(actual, expected) and zip_not_disjoint?(actuals, expecteds)

  defp zip_not_disjoint?([], []), do: true

  # Types are printed only for reported findings.
  defp finding(base, severity, check, message) do
    base
    |> Map.drop([:spec_clauses, :inferred_clauses])
    |> Map.merge(%{
      severity: severity,
      check: check,
      message: message,
      spec: Enum.map(base.spec_clauses, &spec_string(base.function, &1)),
      inferred: Enum.map(base.inferred_clauses, &signature_string/1)
    })
  end

  defp str(descr), do: to_quoted_string(descr)

  defp spec_string(name, clause),
    do: "@spec " <> (name |> Code.Typespec.spec_to_quoted(clause) |> Macro.to_string())

  defp signature_string({args, return}),
    do: "(#{Enum.map_join(args, ", ", &str/1)}) -> #{str(return)}"
end
