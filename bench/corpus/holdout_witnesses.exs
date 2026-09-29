# Direct, side-effect-free witnesses from the pinned Ash holdout. The input
# values and output predicates are independent of SpecLint's translator.
#
#   elixir bench/corpus/holdout_witnesses.exs /tmp/spec-lint-expansion
#
# Every observation has a stable `case` id (the id the evaluation inventory
# cites), whether its input satisfies the cited @spec argument types
# (`input_in_declared_domain`) and whether its result is outside the cited
# @spec return (`outside_declared_return`), each decided by a hand-written
# predicate over the declared types cited in `spec` (evaluation inventory
# version 2; version 1 recorded only the result). A witness counts only
# with an in-domain input and a result outside the declared return; a
# control is an in-domain input whose result is inside it.

root = List.first(System.argv()) || "/tmp/spec-lint-expansion"
ash = Path.join(root, "ash")
pins = __DIR__ |> Path.join("expansion.json") |> File.read!() |> JSON.decode!()
{revision, 0} = System.cmd("git", ["-C", ash, "rev-parse", "HEAD"])

unless String.trim(revision) == pins["ash"]["revision"] do
  raise "Ash checkout does not match the pinned holdout revision"
end

ebin = Path.join([ash, "_build", "test", "lib", "ash", "ebin"])
unless File.dir?(ebin), do: raise("compiled Ash ebin missing: #{ebin}")
Code.prepend_path(ebin)

defmodule HoldoutWitness.Types do
  @moduledoc false
  # Predicates for the declared types, spelled out from the cited source.

  # Ash.Page.page() (ash/lib/ash/page/page.ex:7): Keyset.t() | Offset.t().
  @spec page?(term()) :: boolean()
  def page?(%{__struct__: module}), do: module in [Ash.Page.Keyset, Ash.Page.Offset]
  def page?(_), do: false

  # Ash.Resource.record() (ash/lib/ash/resource.ex:13): struct().
  @spec record?(term()) :: boolean()
  def record?(%{__struct__: module}) when is_atom(module), do: true
  def record?(_), do: false

  # Ash.Error.class_module() (Splode, from ash/lib/ash/error/error.ex:10-15).
  @spec class_module?(term()) :: boolean()
  def class_module?(module),
    do: module in [Ash.Error.Forbidden, Ash.Error.Invalid, Ash.Error.Framework, Ash.Error.Unknown]

  # Ash.Error.t() (Splode's t(): an exception map with an error class).
  @spec ash_error?(term()) :: boolean()
  def ash_error?(%{__exception__: true, class: class, bread_crumbs: crumbs, vars: vars})
      when class in [:forbidden, :invalid, :framework, :unknown],
      do: is_list(crumbs) and Keyword.keyword?(vars)

  def ash_error?(_), do: false

  # Ash.load_statement() (ash/lib/ash.ex:36-41): Ash.Query.t() | [atom] |
  # atom | Keyword.t() | list(atom | {atom, atom | Keyword.t()}).
  @spec load_statement?(term()) :: boolean()
  def load_statement?(value) when is_atom(value), do: true
  def load_statement?(%Ash.Query{}), do: true

  def load_statement?(value) when is_list(value) do
    Enum.all?(value, fn
      atom when is_atom(atom) -> true
      {key, nested} when is_atom(key) -> is_atom(nested) or Keyword.keyword?(nested)
      _ -> false
    end)
  end

  def load_statement?(_), do: false
end

alias HoldoutWitness.Types

# observe(case, role, mfa, spec, input, fun, in_domain?, declared?)
observe = fn id, role, mfa, spec, input, fun, in_domain?, declared? ->
  result = fun.()
  outside? = not declared?.(result)

  verdict =
    cond do
      not in_domain? -> :input_outside_declared_domain
      role == :witness and outside? -> :witnessed
      role == :witness -> :refuted
      outside? -> :control_failed
      true -> :control_inside
    end

  %{
    case: id,
    role: role,
    mfa: mfa,
    spec: spec,
    input: input,
    input_in_declared_domain: in_domain?,
    result: inspect(result),
    outside_declared_return: outside?,
    verdict: verdict
  }
end

page_opts_spec =
  "ash/lib/ash/page/page.ex:13 page_opts(page() | false | nil | Keyword.t()) :: " <>
    "{:ok, page()} | {:error, String.t()}"

page_opts_domain? = fn value ->
  value in [false, nil] or Keyword.keyword?(value) or Types.page?(value)
end

page_opts_declared? = fn
  {:ok, page} -> Types.page?(page)
  {:error, message} -> is_binary(message)
  _ -> false
end

load_spec =
  "ash/lib/ash.ex:2436-2448 load(record_or_records | Ash.Page.page() | {:ok, _} | " <>
    "{:error, term} | :ok | nil, load_statement(), Keyword.t()) :: " <>
    "{:ok, Ash.Resource.record() | [Ash.Resource.record()] | nil} | {:error, term}"

load_domain? = fn data, query, opts ->
  data in [:ok, nil] and Types.load_statement?(query) and Keyword.keyword?(opts)
end

load_declared? = fn
  {:ok, value} ->
    is_nil(value) or Types.record?(value) or
      (is_list(value) and Enum.all?(value, &Types.record?/1))

  {:error, _} ->
    true

  _ ->
    false
end

refute_spec =
  "ash/lib/ash/test.ex:109-118 refute_has_error(Ash.Changeset.t() | Ash.Query.t() | " <>
    "Ash.ActionInput.t() | :ok | {:ok, term} | {:error, term}, Ash.Error.class_module(), " <>
    "(Ash.Error.t() -> boolean)) :: Ash.Error.t() | no_return"

callback = fn _ -> false end

observations = [
  observe.(
    "ash_page_opts_false",
    :witness,
    "Ash.Page.page_opts/1",
    page_opts_spec,
    "Ash.Page.page_opts(false)",
    fn -> Ash.Page.page_opts(false) end,
    page_opts_domain?.(false),
    page_opts_declared?
  ),
  observe.(
    "ash_page_opts_nil",
    :witness,
    "Ash.Page.page_opts/1",
    page_opts_spec,
    "Ash.Page.page_opts(nil)",
    fn -> Ash.Page.page_opts(nil) end,
    page_opts_domain?.(nil),
    page_opts_declared?
  ),
  observe.(
    "ash_load_ok",
    :witness,
    "Ash.load/3",
    load_spec,
    "Ash.load(:ok, nil, [])",
    fn -> Ash.load(:ok, nil, []) end,
    load_domain?.(:ok, nil, []),
    load_declared?
  ),
  observe.(
    "ash_load_nil",
    :control,
    "Ash.load/3",
    load_spec,
    "Ash.load(nil, nil, [])",
    fn -> Ash.load(nil, nil, []) end,
    load_domain?.(nil, nil, []),
    load_declared?
  ),
  observe.(
    "ash_refute_has_error_ok",
    :witness,
    "Ash.Test.refute_has_error/3",
    refute_spec,
    "Ash.Test.refute_has_error(:ok, Ash.Error.Invalid, fn _ -> false end)",
    fn -> Ash.Test.refute_has_error(:ok, Ash.Error.Invalid, callback) end,
    Types.class_module?(Ash.Error.Invalid) and is_function(callback, 1),
    &Types.ash_error?/1
  )
]

# The verdicts are part of the claim: fail loudly if a pinned observation moves.
expected = %{
  "ash_page_opts_false" => {:witnessed, "{:ok, false}"},
  "ash_page_opts_nil" => {:witnessed, "{:ok, nil}"},
  "ash_load_ok" => {:witnessed, "{:ok, :ok}"},
  "ash_load_nil" => {:control_inside, "{:ok, nil}"},
  "ash_refute_has_error_ok" => {:witnessed, ":ok"}
}

for o <- observations do
  unless {o.verdict, o.result} == Map.fetch!(expected, o.case) do
    raise "a pinned Ash witness changed: #{inspect(o)}"
  end
end

IO.puts(
  JSON.encode!(%{
    schema: "spec_lint/holdout_witnesses",
    version: 2,
    ash_revision: String.trim(revision),
    observations: observations
  })
)
