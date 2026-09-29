# Prints, row by row, the compiler internals of bench/corpus/toolchain/
# audit-1.20.4.md as the running Elixir build has them, calling
# Module.Types.Descr directly (not through SpecLint's adapters), so the
# output of two builds can be compared:
#
#     elixir bench/corpus/toolchain/audit_probe.exs
#
# Functions that only one compiler line exports are called with apply/3.
# Needs only the running build. Writes nothing.

alias Module.Types.Descr, as: D

for m <-
      [D, Module.Types, Module.Types.Apply, Module.Types.Pattern, Module.ParallelChecker] ++
        [Code.Typespec, Mix.Compilers.Elixir],
    do: {:module, _} = Code.ensure_loaded(m)

exported? = &function_exported?(D, &1, &2)
v121? = exported?.(:opt_union, 2)
union = fn a, b -> apply(D, if(v121?, do: :opt_union, else: :union), [a, b]) end
difference = fn a, b -> apply(D, if(v121?, do: :opt_difference, else: :difference), [a, b]) end

show = fn label, value ->
  IO.puts("#{label}: " <> inspect(value, limit: 50, printable_limit: 200))
end

dnf = fn descr, kind -> D.bdd_to_dnf(Map.fetch!(descr, kind)) end
int = D.integer()
ok = D.atom([:ok])

IO.puts("build #{System.version()} #{System.build_info()[:revision]} OTP #{System.otp_release()}")

show.(
  "row 1 line-specific Descr exports",
  for(
    {f, a} <-
      [opt_union: 2, opt_intersection: 2, opt_difference: 2, unfold: 1, recursive: 1] ++
        [union: 2, intersection: 2, difference: 2, if_set: 1, not_set: 0],
    do: {f, a, exported?.(f, a)}
  )
)

show.(
  "row 2 bitmap",
  for(
    k <- ~w(binary bitstring_no_binary empty_list integer float pid port reference)a,
    do: {k, apply(D, k, [])}
  )
)

show.("row 3 atoms", {ok, difference.(D.atom(), ok)})
show.("row 4/28 tuples", {dnf.(D.tuple([ok]), :tuple), dnf.(D.open_tuple([ok]), :tuple)})

show.(
  "row 26 closed_map, 1.21 field form {v, optional?}",
  try do
    D.closed_map([{:a, {int, true}}])
    |> dnf.(:map)
  rescue
    e -> {:raised, Exception.message(e) |> String.split("\n") |> hd()}
  end
)

if exported?.(:if_set, 1) do
  optional = :erlang.apply(D, :if_set, [int])
  show.("row 26 if_set(integer())", optional)

  show.(
    "row 26 closed_map, 1.20 form (optional a, required b, binary domain)",
    dnf.(D.closed_map([{:a, optional}, {:b, int}, {[:binary], D.atom()}]), :map)
  )
end

show.("row 5 open_map", dnf.(D.open_map(), :map))
show.("row 5 empty_map", D.empty_map())

show.(
  "row 27 to_domain_keys",
  for(
    t <-
      [D.binary(), D.bitstring_no_binary(), D.empty_list(), D.list(int), D.atom(), ok] ++
        [D.tuple(), D.open_map(), D.fun(), D.dynamic(int)],
    do: t |> D.to_domain_keys() |> Enum.sort()
  )
)

show.("row 27 to_domain_keys(term())", D.to_domain_keys(D.term()) |> Enum.sort())

for name <- [:bitstring, :bitstring_no_binary] do
  show.("row 27 closed_map domain #{name}", dnf.(D.closed_map([{[name], int}]), :map))
end

show.("row 6/29 list", {dnf.(D.non_empty_list(int, D.empty_list()), :list), D.list(int)})
show.("row 7/30 fun", {D.fun(), D.fun(1)})
show.("row 8/31 dynamic/term/none", {D.dynamic(int), D.dynamic(), D.term(), D.none()})
show.("row 31 upper_bound(dynamic())", D.upper_bound(D.dynamic()))

show.(
  "row 32 unfold/1 and recursive/1 exported",
  {exported?.(:unfold, 1), exported?.(:recursive, 1)}
)

if exported?.(:unfold, 1) do
  show.(
    "row 33 unfold(term()) kinds",
    :erlang.apply(D, :unfold, [D.term()]) |> Map.keys() |> Enum.sort()
  )
else
  parts =
    [D.bitstring(), D.empty_list(), D.integer(), D.float(), D.pid(), D.port(), D.reference()] ++
      [D.atom(), D.tuple(), D.open_map(), D.non_empty_list(D.term(), D.term()), D.fun()]

  term = Enum.reduce(parts, &union.(&2, &1))

  show.(
    "row 33 union of kind tops: kinds, equal to term()",
    {term |> Map.keys() |> Enum.sort(), D.equal?(term, D.term())}
  )
end

show.(
  "row 9 contravariance",
  {D.subtype?(D.fun([D.atom()], int), D.fun([ok], int)),
   D.subtype?(D.fun([ok], int), D.fun([D.atom()], int))}
)

show.(
  "row 9 gradual bounds",
  {D.equal?(D.upper_bound(D.dynamic(int)), int), D.empty?(D.lower_bound(D.dynamic(int))),
   D.gradual?(D.dynamic(int)), D.gradual?(int)}
)

show.(
  "row 9 atom_fetch",
  {D.atom_fetch(D.atom([:b, :a])), D.atom_fetch(D.atom()), D.atom_fetch(int)}
)

show.("row 9 union commutes", D.equal?(union.(int, D.float()), union.(D.float(), int)))

show.(
  "row 9 to_quoted_string skip_dynamic_for_indivisible: false",
  D.to_quoted_string(D.dynamic(int), skip_dynamic_for_indivisible: false)
)

show.("row 10 checker_version", :elixir_erl.checker_version())

{:ok, {_, [{~c"ExCk", bytes}]}} = :beam_lib.chunks(:code.which(Keyword), [~c"ExCk"])
{version, contents} = :erlang.binary_to_term(bytes)

show.(
  "row 11 Keyword ExCk",
  {version, Map.keys(contents), contents.mode, length(contents.exports),
   Enum.frequencies_by(contents.exports, fn {_, i} -> elem(i.sig, 0) end)}
)

kinds =
  for app <- ~w(elixir eex ex_unit iex logger mix)a,
      beam <- Path.wildcard(Path.join(:code.lib_dir(app), "ebin/*.beam")),
      {:ok, {_, [{~c"ExCk", b}]}} <- [:beam_lib.chunks(String.to_charlist(beam), [~c"ExCk"])],
      {_, %{exports: exports}} = :erlang.binary_to_term(b),
      {_, info} <- exports,
      do:
        (case Map.get(info, :sig) do
           {kind, _, _} -> kind
           other -> other
         end)

show.("row 12 stdlib exports by stored signature kind", Enum.frequencies(kinds))

show.(
  "row 13 remote_apply/7, stack/7, context/0",
  {function_exported?(Module.Types.Apply, :remote_apply, 7),
   function_exported?(Module.Types, :stack, 7), function_exported?(Module.Types, :context, 0)}
)

show.(
  "row 16 warnings/6, ParallelChecker start_link/1 stop/1",
  {function_exported?(Module.Types, :warnings, 6),
   function_exported?(Module.ParallelChecker, :start_link, 1),
   function_exported?(Module.ParallelChecker, :stop, 1)}
)

show.(
  "row 17 Pattern.of_head/8, of_guard/5",
  {function_exported?(Module.Types.Pattern, :of_head, 8),
   function_exported?(Module.Types.Pattern, :of_guard, 5)}
)

forms = [
  {:attribute, 1, :module, :audit_typespec_probe},
  {:attribute, 1, :export_type, [t: 0, o: 0, n: 0]},
  {:attribute, 1, :type, {:t, {:type, 1, :integer, []}, []}},
  {:attribute, 1, :opaque, {:o, {:type, 1, :atom, []}, []}},
  {:attribute, 1, :type, {:p, {:type, 1, :float, []}, []}},
  {:attribute, 1, :nominal, {:n, {:type, 1, :binary, []}, []}}
]

{:ok, _, binary} = :compile.forms(forms, [:binary, :debug_info])
{:ok, types} = Code.Typespec.fetch_types(binary)

show.(
  "row 18 fetch_types kinds of a module with type, typep, opaque, nominal",
  types |> Enum.map(&elem(&1, 0)) |> Enum.sort()
)

source = """
defmodule AuditIntoProbe do
  def f(flag, value) do
    into = if flag, do: [], else: ""
    _ = for _ <- [1], do: value, into: into
    value
  end
end
"""

[{AuditIntoProbe, into}] = Code.compile_string(source)
{:ok, {_, [{~c"ExCk", b}]}} = :beam_lib.chunks(into, [~c"ExCk"])
{_, %{exports: exports}} = :erlang.binary_to_term(b)
{_, %{sig: {:infer, _, [{args, return}]}}} = List.keyfind(exports, {:f, 2}, 0)

show.(
  "row 19 stored f/2 of the for-into probe",
  {Enum.map(args, &D.to_quoted_string/1), D.to_quoted_string(return)}
)

show.(
  "row 20 read_manifest of an unreadable path",
  Mix.Compilers.Elixir.read_manifest("/dev/null/x")
)

show.("row 21 revision", System.build_info()[:revision])
show.("row 22 Module.Types.warnings/7", function_exported?(Module.Types, :warnings, 7))

clauses = """
defmodule AuditClauses do
  def idx(:a), do: raise(ArgumentError, "no :a")
  def idx(:b), do: {:error, :b}
  def direct(:b = x) when is_integer(x) and is_atom(x), do: {:error, :bad}
  def direct(x) when is_atom(x), do: :ok
end
"""

{[{AuditClauses, binary}], diagnostics} =
  Code.with_diagnostics(fn -> Code.compile_string(clauses) end)

show.(
  "row 35 compiler diagnostics for the impossible compound guard of direct/1",
  for(
    %{message: message, position: position} <- diagnostics,
    do: {position, message |> String.split("\n") |> hd()}
  )
)

{:ok, {_, [{~c"ExCk", b}]}} = :beam_lib.chunks(binary, [~c"ExCk"])
{_, %{exports: exports}} = :erlang.binary_to_term(b)
{_, %{sig: {:infer, _, idx}}} = List.keyfind(exports, {:idx, 1}, 0)

show.(
  "row 34 stored clauses of idx/1 (source clause 0 raises)",
  for({a, r} <- idx, do: {Enum.map(a, &D.to_quoted_string/1), D.to_quoted_string(r)})
)
