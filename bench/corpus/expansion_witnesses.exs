# Run with: elixir bench/corpus/expansion_witnesses.exs /tmp/spec-lint-expansion
# Uses compiled library BEAMs without starting either application. The checks
# below are direct values and type predicates; they do not call SpecLint.

root =
  System.argv() |> List.first() ||
    System.get_env("SPEC_LINT_EXPANSION_ROOT") ||
    "/tmp/spec-lint-expansion"

pins = __DIR__ |> Path.join("expansion.json") |> File.read!() |> JSON.decode!()

for app <- ~w(req oban) do
  {revision, status} = System.cmd("git", ["-C", Path.join(root, app), "rev-parse", "HEAD"])

  unless status == 0 and String.trim(revision) == pins[app]["revision"] do
    raise "#{app} must be at the revision pinned in expansion.json"
  end

  ebin =
    ["test", "dev"]
    |> Enum.map(&Path.join([root, app, "_build", &1, "lib", app, "ebin"]))
    |> Enum.find(&File.dir?/1)

  if ebin == nil do
    abort = "compiled #{app} ebin not found under #{root}; compile the pinned copy first"
    IO.puts(:stderr, abort)
    System.halt(2)
  end

  Code.prepend_path(ebin)
end

unless Code.ensure_loaded?(Req.Response) and Code.ensure_loaded?(Oban.Period) and
         Code.ensure_loaded?(Oban.Registry) do
  IO.puts(:stderr, "could not load Req.Response, Oban.Period and Oban.Registry")
  System.halt(2)
end

# The argument is in new/1's declared map() domain. t() requires a
# non-negative status, yet the constructor stores the negative value.
req_bad = Req.Response.new(%{status: -1})
req_good = Req.Response.new(%{status: 200})

# to_seconds/1 accepts 0 at runtime, but its declared Period.t() input
# requires a positive integer. Its zero return is therefore not a return
# counterexample within the spec domain.
oban_bad = Oban.Period.to_seconds(0)
oban_good = Oban.Period.to_seconds(1)

# name(), role() and value() all include these inputs. The nil value uses
# the promised inner two-tuple; a non-nil value makes an inner three-tuple.
via_bad = Oban.Registry.via(Oban, nil, :witness)
via_good = Oban.Registry.via(Oban, nil, nil)

observations = [
  %{
    case: "req_response_new_broad_map",
    source: "req/lib/req/response.ex:23,54,57,72",
    revision: "c6e8ab1f9d1c8e1aef935a6319faa40487bb6f42",
    mfa: "Req.Response.new/1",
    input: "%{status: -1}",
    input_in_declared_domain: true,
    output: "%Req.Response{status: -1}",
    observed_status: req_bad.status,
    output_in_declared_domain:
      match?(
        %{__struct__: Req.Response, status: status} when is_integer(status) and status >= 0,
        req_bad
      ),
    explanation: "new/1 accepts map(); Req.Response.t() requires status: non_neg_integer()."
  },
  %{
    case: "req_response_new_control",
    source: "req/lib/req/response.ex:23,54,57,72",
    revision: "c6e8ab1f9d1c8e1aef935a6319faa40487bb6f42",
    mfa: "Req.Response.new/1",
    input: "%{status: 200}",
    input_in_declared_domain: true,
    observed_status: req_good.status,
    output_in_declared_domain:
      match?(
        %{__struct__: Req.Response, status: status} when is_integer(status) and status >= 0,
        req_good
      )
  },
  %{
    case: "oban_registry_via_non_nil_value",
    source: "oban/lib/oban/registry.ex:6-8,122-128",
    revision: "23fa8176b3586ca84f5859793739fad798e69d2b",
    mfa: "Oban.Registry.via/3",
    input: "(Oban, nil, :witness)",
    input_in_declared_domain: true,
    observed_return: inspect(via_bad),
    output_in_declared_domain: match?({:via, Registry, {Oban.Registry, _key}}, via_bad),
    explanation: "The spec promises an inner two-tuple; non-nil value produces three elements."
  },
  %{
    case: "oban_registry_via_nil_control",
    source: "oban/lib/oban/registry.ex:6-8,122-128",
    revision: "23fa8176b3586ca84f5859793739fad798e69d2b",
    mfa: "Oban.Registry.via/3",
    input: "(Oban, nil, nil)",
    input_in_declared_domain: true,
    observed_return: inspect(via_good),
    output_in_declared_domain: match?({:via, Registry, {Oban.Registry, _key}}, via_good)
  },
  %{
    case: "oban_period_zero_outside_domain",
    source: "oban/lib/oban/period.ex:41,59,64,84,90",
    revision: "23fa8176b3586ca84f5859793739fad798e69d2b",
    mfa: "Oban.Period.to_seconds/1",
    input: "0",
    input_in_declared_domain: false,
    observed_return: oban_bad,
    output_in_declared_domain: is_integer(oban_bad) and oban_bad > 0,
    explanation:
      "Runtime guard accepts zero, but Period.t() and the return spec require pos_integer()."
  },
  %{
    case: "oban_period_positive_control",
    source: "oban/lib/oban/period.ex:41,84,90",
    revision: "23fa8176b3586ca84f5859793739fad798e69d2b",
    mfa: "Oban.Period.to_seconds/1",
    input: "1",
    input_in_declared_domain: true,
    observed_return: oban_good,
    output_in_declared_domain: is_integer(oban_good) and oban_good > 0
  }
]

IO.puts(JSON.encode!(%{schema: "spec_lint/expansion_witnesses", observations: observations}))
