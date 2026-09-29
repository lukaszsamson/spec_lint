# Controlled integration witnesses for the source-only Ash reports in
# holdout_triage.md. It builds a minimal Ash domain with ETS-backed resources
# from the pinned, already compiled Ash checkout and calls the public
# functions and records, for each witness and control input, whether it
# satisfies the declared @spec (checked by hand-written predicates over the
# cited struct fields, see Support.query_t?/1 and Support.authorizer_t?/1).
# A report counts as witnessed only when the witness input is inside the
# declared domain. Nothing here calls SpecLint; the "inside declared return"
# predicates are hand-written from the @spec text cited on each witness.
#
#   elixir bench/corpus/ash_integration_witnesses.exs /tmp/spec-lint-expansion
#
# No network and no disk: ETS tables are private and in memory. The script
# loads Ash and its dependency BEAMs from `_build/test/lib/*/ebin` and starts
# only the applications the exercised code paths need.

root = List.first(System.argv()) || "/tmp/spec-lint-expansion"
ash_root = Path.join(root, "ash")
pins = __DIR__ |> Path.join("expansion.json") |> File.read!() |> JSON.decode!()
{revision, 0} = System.cmd("git", ["-C", ash_root, "rev-parse", "HEAD"])

unless String.trim(revision) == pins["ash"]["revision"] do
  raise "Ash checkout does not match the pinned holdout revision"
end

libs = Path.join([ash_root, "_build", "test", "lib"])
unless File.dir?(libs), do: raise("compiled Ash build missing: #{libs}")

for ebin <- Path.wildcard(Path.join([libs, "*", "ebin"])), do: Code.prepend_path(ebin)

Application.put_env(:spark, :skip_diagnostic_warnings, true)

# Ash's runtime reads its application env and uses telemetry, ETS-backed
# tables and its own supervisor-free helpers. Start the leaf apps explicitly
# rather than everything listed in ash.app (igniter, benchee, mimic, ...).
for app <- [:telemetry, :decimal, :jason, :spark, :ecto, :ets, :splode, :ash] do
  case Application.ensure_all_started(app, :temporary) do
    {:ok, _} -> :ok
    {:error, reason} -> raise "could not start #{app}: #{inspect(reason)}"
  end
end

Logger.configure(level: :warning)

# Ash's resource verifier reads Mix.Project.config/0.
Mix.start()

{_, diagnostics} =
  Code.with_diagnostics(fn ->
    defmodule Witness.ExplodingCalc do
      @moduledoc false
      use Ash.Resource.Calculation

      @impl true
      def calculate(_records, _opts, _context), do: {:error, "witness calculation failure"}
    end

    defmodule Witness.FineCalc do
      @moduledoc false
      use Ash.Resource.Calculation

      @impl true
      def calculate(records, _opts, _context), do: Enum.map(records, & &1.title)
    end

    defmodule Witness.Post do
      @moduledoc false
      use Ash.Resource, domain: Witness.Domain, data_layer: Ash.DataLayer.Ets

      ets do
        private?(true)
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:title, :string, allow_nil?: false, public?: true)
      end

      calculations do
        calculate(:exploding, :string, Witness.ExplodingCalc, public?: true)
        calculate(:fine, :string, Witness.FineCalc, public?: true)
      end

      actions do
        default_accept([:title])
        defaults([:read, create: :*])

        read :keyset do
          pagination(
            keyset?: true,
            offset?: false,
            required?: false,
            countable: true,
            default_limit: 1
          )
        end
      end
    end

    # Every builtin policy check decides during the strict check, so the boolean
    # requirement folds to a constant before the SAT solver runs. Reaching the
    # solver's empty-scenario branch needs checks that stay `:unknown` at strict
    # time and are declared mutually exclusive through the documented
    # Ash.Policy.Check `conflicts?/3` callback. These two custom checks do that.
    defmodule Witness.CheckA do
      @moduledoc false
      use Ash.Policy.Check

      @impl true
      def describe(_opts), do: "witness check A"

      @impl true
      def strict_check(_actor, _authorizer, _opts), do: {:ok, :unknown}

      @impl true
      def check(_actor, data, _authorizer, _opts), do: data

      @impl true
      def conflicts?({__MODULE__, _}, {Witness.CheckB, _}, _context), do: true
      def conflicts?(_, _, _), do: false
    end

    defmodule Witness.CheckB do
      @moduledoc false
      use Ash.Policy.Check

      @impl true
      def describe(_opts), do: "witness check B"

      @impl true
      def strict_check(_actor, _authorizer, _opts), do: {:ok, :unknown}

      @impl true
      def check(_actor, data, _authorizer, _opts), do: data

      @impl true
      def conflicts?({__MODULE__, _}, {Witness.CheckA, _}, _context), do: true
      def conflicts?(_, _, _), do: false
    end

    # Both policies are applicable to every request and both must authorize, but
    # check A and check B are declared mutually exclusive.
    defmodule Witness.Contradictory do
      @moduledoc false
      use Ash.Resource,
        domain: Witness.Domain,
        data_layer: Ash.DataLayer.Ets,
        authorizers: [Ash.Policy.Authorizer]

      ets do
        private?(true)
      end

      attributes do
        uuid_primary_key(:id)
      end

      actions do
        defaults([:read])
      end

      policies do
        policy always() do
          authorize_if(Witness.CheckA)
        end

        policy always() do
          authorize_if(Witness.CheckB)
        end
      end
    end

    defmodule Witness.Satisfiable do
      @moduledoc false
      use Ash.Resource,
        domain: Witness.Domain,
        data_layer: Ash.DataLayer.Ets,
        authorizers: [Ash.Policy.Authorizer]

      ets do
        private?(true)
      end

      attributes do
        uuid_primary_key(:id)
      end

      actions do
        defaults([:read])
      end

      policies do
        policy always() do
          authorize_if(Witness.CheckA)
        end
      end
    end

    defmodule Witness.Domain do
      @moduledoc false
      use Ash.Domain, validate_config_inclusion?: false

      resources do
        resource(Witness.Post)
        resource(Witness.Contradictory)
        resource(Witness.Satisfiable)
      end
    end

    defmodule Witness.Support do
      @moduledoc false

      # Short structural rendering of an observed value: structs collapse to
      # `%Mod{}`, lists of records to `[%Mod{}, ...(n)]`, strings stay verbatim.
      @spec shape(term()) :: String.t()
      def shape(%{__struct__: mod}), do: "%#{inspect(mod)}{}"

      def shape(t) when is_tuple(t),
        do: "{" <> Enum.map_join(Tuple.to_list(t), ", ", &shape/1) <> "}"

      def shape([]), do: "[]"

      def shape([h | _] = l) when is_list(l),
        do: "[" <> shape(h) <> ", ...(#{length(l)})]"

      def shape(m) when is_map(m), do: "%{...}"
      def shape(f) when is_function(f), do: "#Function"
      def shape(other), do: inspect(other)

      # Ash.Error.t() is an exception carrying an error class.
      @spec ash_error?(term()) :: boolean()
      def ash_error?(%{__exception__: true, class: class})
          when class in [:invalid, :forbidden, :framework, :unknown],
          do: true

      def ash_error?(_), do: false

      @spec record?(term()) :: boolean()
      def record?(%{__struct__: mod}) when is_atom(mod), do: true
      def record?(_), do: false

      @spec records?(term()) :: boolean()
      def records?(v), do: is_list(v) and Enum.all?(v, &record?/1)

      @spec page?(term()) :: boolean()
      def page?(%Ash.Page.Keyset{}), do: true
      def page?(%Ash.Page.Offset{}), do: true
      def page?(_), do: false

      # Ash.Page.Keyset.t() field types, spelled out from the @type in
      # ash/lib/ash/page/keyset.ex:16-24.
      @spec valid_keyset_page?(term()) :: boolean()
      def valid_keyset_page?(%Ash.Page.Keyset{} = p) do
        records?(p.results) and non_neg?(p.count) and binary_or_nil?(p.before) and
          binary_or_nil?(p.after) and pos_integer?(p.limit) and is_boolean(p.more?) and
          rerun?(p.rerun)
      end

      def valid_keyset_page?(_), do: false

      @spec non_neg?(term()) :: boolean()
      defp non_neg?(v), do: is_integer(v) and v >= 0

      @spec pos_integer?(term()) :: boolean()
      defp pos_integer?(v), do: is_integer(v) and v > 0

      @spec binary_or_nil?(term()) :: boolean()
      defp binary_or_nil?(v), do: is_nil(v) or is_binary(v)

      @spec rerun?(term()) :: boolean()
      defp rerun?({query, opts}), do: query_t?(query) and Keyword.keyword?(opts)
      defp rerun?(_), do: false

      # Ash.Query.t() (ash/lib/ash/query/query.ex:206-246), every field whose
      # declared type is not a function, filter or nested Ash struct. A query
      # from Ash.Query.new/1 leaves distinct at nil, outside `[atom]`, and a
      # loaded calculation puts an %Ash.Query.Calculation{} where the type
      # allows only `:wat`.
      @spec query_t?(term()) :: boolean()
      def query_t?(%Ash.Query{} = query) do
        fields_valid?(query,
          __validated_for_action__: &is_atom/1,
          domain: &is_atom/1,
          distinct: &atoms?/1,
          resource: &is_atom/1,
          timeout: &(is_nil(&1) or pos_integer?(&1)),
          action_failed?: &is_boolean/1,
          combination_of: &is_list/1,
          after_action: &is_list/1,
          authorize_results: &is_list/1,
          aggregates: &is_map/1,
          arguments: &is_map/1,
          before_action: &is_list/1,
          before_transaction: &is_list/1,
          after_transaction: &is_list/1,
          around_transaction: &is_list/1,
          calculations: &(is_map(&1) and Enum.all?(Map.values(&1), fn v -> v == :wat end)),
          context: &is_map/1,
          errors: &is_list/1,
          limit: &(is_nil(&1) or non_neg?(&1)),
          load: &Keyword.keyword?/1,
          offset: &non_neg?/1,
          page: &(&1 in [nil, false] or Keyword.keyword?(&1)),
          params: &is_map/1,
          phase: &(&1 in [:preparing, :before_action, :after_action, :executing]),
          select: &(is_nil(&1) or atoms?(&1)),
          sort: &is_list/1,
          valid?: &is_boolean/1
        )
      end

      def query_t?(_), do: false

      # Ash.Policy.Authorizer.t() (ash/lib/ash/policy/authorizer/authorizer.ex:27-45),
      # the fields whose declared type is checkable here.
      @spec authorizer_t?(term()) :: boolean()
      def authorizer_t?(%Ash.Policy.Authorizer{} = authorizer) do
        fields_valid?(authorizer,
          resource: &is_atom/1,
          query: &(is_nil(&1) or query_t?(&1)),
          subject: &query_t?/1,
          context: &is_map/1,
          scenarios: &maps?/1,
          real_scenarios: &maps?/1,
          check_scenarios: &maps?/1,
          policies: &(is_nil(&1) or is_list(&1)),
          facts: &is_map/1,
          data_facts: &is_map/1
        )
      end

      def authorizer_t?(_), do: false

      @spec fields_valid?(struct(), keyword((term() -> boolean()))) :: boolean()
      defp fields_valid?(struct, checks),
        do: Enum.all?(checks, fn {field, check?} -> check?.(Map.fetch!(struct, field)) end)

      @spec atoms?(term()) :: boolean()
      defp atoms?(v), do: is_list(v) and Enum.all?(v, &is_atom/1)

      @spec maps?(term()) :: boolean()
      defp maps?(v), do: is_list(v) and Enum.all?(v, &is_map/1)

      # ash.ex:2758-2759
      @spec read_declared?(term()) :: boolean()
      def read_declared?({:ok, v}), do: records?(v) or page?(v)
      def read_declared?({:error, _}), do: true
      def read_declared?(_), do: false

      # ash.ex:2910-2911 and 2988-2989
      @spec read_one_declared?(term()) :: boolean()
      def read_one_declared?({:ok, v}), do: is_nil(v) or record?(v)
      def read_one_declared?({:error, e}), do: ash_error?(e)
      def read_one_declared?(_), do: false

      # ash.ex:2204-2205
      @spec page_declared?(term()) :: boolean()
      def page_declared?({:ok, p}), do: page?(p)
      def page_declared?({:error, e}), do: ash_error?(e)
      def page_declared?(_), do: false

      # ash/lib/ash/query/query.ex:4346-4347
      @spec apply_to_declared?(term()) :: boolean()
      def apply_to_declared?({:ok, records}), do: records?(records)
      def apply_to_declared?(_), do: false

      # ash/lib/ash/policy/policy.ex:72-74
      @spec solve_declared?(term()) :: boolean()
      def solve_declared?({:ok, v, %Ash.Policy.Authorizer{}}),
        do: is_boolean(v) or (is_list(v) and Enum.all?(v, &is_map/1))

      def solve_declared?({:error, %Ash.Policy.Authorizer{}, e}), do: ash_error?(e)
      def solve_declared?(_), do: false
    end
  end)

if Enum.any?(diagnostics, &(&1.severity == :error)) do
  raise "witness modules did not compile: #{inspect(diagnostics)}"
end

alias Witness.{Domain, Post, Support}

Ash.create!(Post, %{title: "first"}, domain: Domain)

# witness(report, mfa, spec_ref, witness_desc, witness_thunk, control_desc,
# control_thunk, declared?, {witness_in_domain?, control_in_domain?}) --
# declared? is the hand-written predicate for the cited @spec return type,
# and the two booleans record whether each input satisfies the cited @spec.
witness = fn report, mfa, spec_ref, w_desc, w_fun, c_desc, c_fun, declared?, {w_in?, c_in?} ->
  w = w_fun.()
  c = c_fun.()
  outside? = not declared?.(w)
  control_inside? = declared?.(c)

  verdict =
    cond do
      not control_inside? -> :control_failed
      not w_in? and outside? -> :escape_outside_declared_domain
      not w_in? -> :no_escape_outside_declared_domain
      outside? -> :witnessed
      true -> :refuted
    end

  %{
    report: report,
    mfa: mfa,
    spec: spec_ref,
    witness_input: w_desc,
    witness_input_in_declared_domain: w_in?,
    observed: Support.shape(w),
    outside_declared_return: outside?,
    control_input: c_desc,
    control_input_in_declared_domain: c_in?,
    control_observed: Support.shape(c),
    control_inside_declared_return: control_inside?,
    verdict: verdict
  }
end

# Ash.Query.new/1 leaves distinct at nil, outside Ash.Query.t()'s `[atom]`.
in_domain_query = fn resource -> %{Ash.Query.new(resource) | distinct: []} end
query = in_domain_query.(Post)

unless Support.query_t?(query) do
  raise "witness query is not an Ash.Query.t(): #{inspect(query)}"
end

dq_declared? = fn
  {:ok, %{query: _, ash_query: %{__struct__: Ash.Query}, count: _, run: r, load: l}} ->
    is_function(r) and is_function(l)

  {:error, e} ->
    Support.ash_error?(e)

  _ ->
    false
end

# Ash.Page.Keyset.t() has count :: non_neg_integer(), so ask for a count. The
# page's rerun query comes back with distinct: nil and timeout: :infinity,
# outside Ash.Query.t() (`[atom]`, `pos_integer() | nil`); repair those two
# fields so that every Keyset.t() field, the rerun query included, is valid.
{:ok, read_page} =
  Ash.read(Post, action: :keyset, page: [limit: 1, count: true], domain: Domain)

{rerun_query, rerun_opts} = read_page.rerun
page = %{read_page | rerun: {%{rerun_query | distinct: [], timeout: nil}, rerun_opts}}

if Support.valid_keyset_page?(read_page) do
  raise "the keyset page as read is now a valid Ash.Page.Keyset.t(); revisit the repair"
end

unless Support.valid_keyset_page?(page) do
  raise "witness page is not a fully valid Ash.Page.Keyset.t(): #{inspect(page)}"
end

# Ash.Policy.Authorizer.initial_state/4 leaves subject and the three scenario
# lists at nil, outside Authorizer.t(); fill them with in-domain values.
mk_authorizer = fn resource ->
  action = Ash.Resource.Info.action(resource, :read)
  initial = Ash.Policy.Authorizer.initial_state(nil, resource, action, Domain)

  if Support.authorizer_t?(initial) do
    raise "initial_state/4 now returns a valid Authorizer.t(); revisit the repair"
  end

  authorizer = %{
    initial
    | subject: in_domain_query.(resource),
      scenarios: [],
      real_scenarios: [],
      check_scenarios: []
  }

  unless Support.authorizer_t?(authorizer) do
    raise "witness authorizer is not an Authorizer.t(): #{inspect(authorizer)}"
  end

  authorizer
end

records = Ash.read!(Post, domain: Domain)
exploding = Ash.Query.load(in_domain_query.(Post), :exploding)
fine = Ash.Query.load(in_domain_query.(Post), :fine)

observations = [
  witness.(
    "Ash.read/2 SL002 domain escape",
    "Ash.read/2",
    "ash/lib/ash.ex:2758-2759 (opts :: Keyword.t()); return_query? option at 108-117",
    "Ash.read(Witness.Post, return_query?: true, domain: Witness.Domain)",
    fn -> Ash.read(Post, return_query?: true, domain: Domain) end,
    "Ash.read(Witness.Post, domain: Witness.Domain)",
    fn -> Ash.read(Post, domain: Domain) end,
    &Support.read_declared?/1,
    {true, true}
  ),
  witness.(
    "Ash.read_one/2 SL002 domain escape",
    "Ash.read_one/2",
    "ash/lib/ash.ex:2910-2911 (opts :: Keyword.t()); return_query? in the read-one schema at 163-174",
    "Ash.read_one(Witness.Post, return_query?: true, domain: Witness.Domain)",
    fn -> Ash.read_one(Post, return_query?: true, domain: Domain) end,
    "Ash.read_one(Witness.Post, domain: Witness.Domain)",
    fn -> Ash.read_one(Post, domain: Domain) end,
    &Support.read_one_declared?/1,
    {true, true}
  ),
  witness.(
    "Ash.read_first/2 SL002 domain escape",
    "Ash.read_first/2",
    "ash/lib/ash.ex:2988-2989 (opts :: Keyword.t()); same read-one options schema",
    "Ash.read_first(Witness.Post, return_query?: true, domain: Witness.Domain)",
    fn -> Ash.read_first(Post, return_query?: true, domain: Domain) end,
    "Ash.read_first(Witness.Post, domain: Witness.Domain)",
    fn -> Ash.read_first(Post, domain: Domain) end,
    &Support.read_one_declared?/1,
    {true, true}
  ),
  witness.(
    "Ash.data_layer_query/2 SL002 domain escape",
    "Ash.data_layer_query/2",
    "ash/lib/ash.ex:2660-2661 (Ash.Query.t(), opts :: Keyword.t()); return_query? is a valid read option",
    "Ash.data_layer_query(%{Ash.Query.new(Witness.Post) | distinct: []}, domain: Witness.Domain, return_query?: true)",
    fn -> Ash.data_layer_query(query, domain: Domain, return_query?: true) end,
    "Ash.data_layer_query(%{Ash.Query.new(Witness.Post) | distinct: []}, domain: Witness.Domain)",
    fn -> Ash.data_layer_query(query, domain: Domain) end,
    dq_declared?,
    {Support.query_t?(query), Support.query_t?(query)}
  ),
  witness.(
    "Ash.page/2 SL002 domain escape",
    "Ash.page/2",
    "ash/lib/ash.ex:2204-2205 with page_request including integer (17-18); Ash.Page.Keyset.t at ash/lib/ash/page/keyset.ex:16-24; Ash.Query.t at ash/lib/ash/query/query.ex:206-246",
    "Ash.page(%Ash.Page.Keyset{} read with action: :keyset, page: [limit: 1, count: true], rerun query repaired to distinct: [], timeout: nil (every Keyset.t() field checked, the rerun query by Support.query_t?/1), 3)",
    fn -> Ash.page(page, 3) end,
    "Ash.page(same keyset page, :self)",
    fn -> Ash.page(page, :self) end,
    &Support.page_declared?/1,
    {Support.valid_keyset_page?(page), Support.valid_keyset_page?(page)}
  ),
  witness.(
    "Ash.Policy.Policy.solve/1 SL002 domain escape",
    "Ash.Policy.Policy.solve/1",
    "ash/lib/ash/policy/policy.ex:72-74 (authorizer :: Authorizer.t()); Authorizer.t at ash/lib/ash/policy/authorizer/authorizer.ex:27-45",
    "Ash.Policy.Policy.solve(initial_state(nil, Witness.Contradictory, :read, Witness.Domain) with subject: %{Ash.Query.new(Witness.Contradictory) | distinct: []} and scenarios, real_scenarios, check_scenarios: []); two applicable policies, authorize_if Witness.CheckA and authorize_if Witness.CheckB; both checks strict-check to :unknown and declare conflicts?/3 with each other",
    fn -> Ash.Policy.Policy.solve(mk_authorizer.(Witness.Contradictory)) end,
    "Ash.Policy.Policy.solve(the same repaired authorizer for Witness.Satisfiable); one applicable policy, authorize_if Witness.CheckA",
    fn -> Ash.Policy.Policy.solve(mk_authorizer.(Witness.Satisfiable)) end,
    &Support.solve_declared?/1,
    {Support.authorizer_t?(mk_authorizer.(Witness.Contradictory)),
     Support.authorizer_t?(mk_authorizer.(Witness.Satisfiable))}
  ),
  witness.(
    "Ash.Query.apply_to/3 SL002 domain escape",
    "Ash.Query.apply_to/3",
    "ash/lib/ash/query/query.ex:4346-4347 (t(), list(record), Keyword.t()); t() declares calculations: %{optional(atom) => :wat}",
    "Ash.Query.apply_to(Ash.Query.load(%{Ash.Query.new(Witness.Post) | distinct: []}, :exploding), records read from Witness.Post, domain: Witness.Domain); :exploding is a calculation whose calculate/3 returns {:error, _}. Loading it puts an %Ash.Query.Calculation{} in calculations, outside t()",
    fn -> Ash.Query.apply_to(exploding, records, domain: Domain) end,
    "Ash.Query.apply_to(the same query loading :fine, records read from Witness.Post, domain: Witness.Domain)",
    fn -> Ash.Query.apply_to(fine, records, domain: Domain) end,
    &Support.apply_to_declared?/1,
    {Support.query_t?(exploding), Support.query_t?(fine)}
  )
]

# The verdicts are part of the claim: fail loudly if a pinned observation moves.
# apply_to/3 escapes only for a query outside t(): any query that loads a
# calculation is, since t() allows only :wat values in calculations.
expected = %{
  "Ash.read/2" => :witnessed,
  "Ash.read_one/2" => :witnessed,
  "Ash.read_first/2" => :witnessed,
  "Ash.data_layer_query/2" => :refuted,
  "Ash.page/2" => :witnessed,
  "Ash.Policy.Policy.solve/1" => :witnessed,
  "Ash.Query.apply_to/3" => :escape_outside_declared_domain
}

for o <- observations do
  unless o.verdict == Map.fetch!(expected, o.mfa) do
    raise "a pinned Ash integration witness changed: #{o.mfa}: #{inspect(o)}"
  end
end

IO.puts(
  JSON.encode!(%{
    schema: "spec_lint/ash_integration_witnesses",
    ash_revision: String.trim(revision),
    observations: observations
  })
)
