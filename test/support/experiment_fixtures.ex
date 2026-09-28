defmodule SpecLint.ExperimentFixtures.Point do
  @moduledoc false
  defstruct x: 0, y: 0

  @type t :: %__MODULE__{x: integer(), y: integer()}
end

defmodule SpecLint.ExperimentFixtures.Secret do
  @moduledoc false

  @opaque t :: {:secret, integer()}

  @spec new(integer()) :: t()
  def new(n), do: {:secret, n}
end

defmodule SpecLint.ExperimentFixtures.Cases do
  @moduledoc false
  # Fixture functions for the Phase 0 SL002 experiment (DESIGN.md 11, item 1).
  # The expected class and ground truth of each one are in
  # SpecLint.ExperimentFixtures.expected/0.

  alias SpecLint.ExperimentFixtures.{Point, Secret}

  @spec lookup(:present | :missing) :: {:ok, integer()}
  def lookup(:present), do: {:ok, 1}
  def lookup(:missing), do: {:error, :missing}

  @spec status(integer()) :: :ok | :error
  def status(0), do: :ok
  def status(n) when is_integer(n) and n > 0, do: :error
  def status(n) when is_integer(n), do: :timeout

  @spec size_of(atom()) :: integer()
  def size_of(:big), do: 1
  def size_of(a) when is_atom(a), do: Atom.to_string(a)

  @spec name(atom()) :: String.t()
  def name(a) when is_atom(a), do: Atom.to_string(a)
  def name(_), do: nil

  @spec display(atom()) :: String.t()
  def display(value) do
    case value do
      a when is_atom(a) -> Atom.to_string(a)
      _ -> nil
    end
  end

  @spec sign(pos_integer()) :: :positive
  def sign(n) when is_integer(n) and n > 0, do: :positive
  def sign(n) when is_integer(n), do: :nonpositive

  @spec decode(binary()) :: {:ok, term()}
  def decode(bin), do: :erlang.binary_to_term(bin)

  @spec kind(atom() | binary()) :: :atom
  def kind(x) when is_atom(x) or is_integer(x) do
    if is_atom(x), do: :atom, else: :integer
  end

  @spec pick(atom()) :: :any_atom
  @spec pick(:special) :: :special
  def pick(:special), do: :special
  def pick(a) when is_atom(a), do: :any_atom

  @spec wide(term()) :: :ok | :error | {:error, term()}
  def wide(_), do: :ok

  @spec fail!(term()) :: no_return()
  def fail!(x), do: raise(ArgumentError, inspect(x))

  @spec find_key([{atom(), term()}], atom()) :: {:ok, term()} | :error
  def find_key([], _key), do: :error
  def find_key([{key, value} | _], key), do: {:ok, value}
  def find_key([_ | rest], key), do: find_key(rest, key)

  @spec count([term()]) :: non_neg_integer()
  def count([]), do: 0
  def count([_ | rest]), do: 1 + count(rest)

  @spec wrap(atom()) :: {:ok, binary()}
  def wrap(a), do: {:ok, only_binary(a)}

  defp only_binary(b) when is_binary(b), do: b

  @spec secret(integer()) :: Secret.t()
  def secret(0), do: {:error, :zero}
  def secret(n) when is_integer(n), do: Secret.new(n)

  @spec point(integer()) :: Point.t()
  def point(0), do: :origin
  def point(n) when is_integer(n), do: %Point{x: n, y: n}

  @spec fetch(integer()) :: {:ok, integer()}
  def fetch(n) when is_integer(n) and n > 0, do: {:ok, n}
  def fetch(n) when is_integer(n), do: %Point{x: n, y: 0}

  @spec labels(:one | :two) :: [binary()]
  def labels(:one), do: ["one"]
  def labels(:two), do: [:two]

  @spec wrap_error(atom()) :: :ok | {:error, atom()}
  def wrap_error(:ok), do: :ok
  def wrap_error(reason) when is_atom(reason), do: error(reason)

  defp error(reason), do: {:error, reason}

  @spec passthrough(tuple()) :: {:ok, integer()}
  def passthrough(t) when is_tuple(t), do: t

  # O2 (Ecto.Query.Builder.Join.escape/3 shape): the precise clauses return
  # 5-tuples, the spec declares 4-tuples, and the recursive catch-all
  # returns dynamic(), which makes the union top-only.
  @spec stale(term()) :: {atom(), term(), term(), list()}
  def stale(x) when is_atom(x), do: {:_, x, nil, nil, []}
  def stale(x) when is_binary(x), do: {:_, {x, nil}, nil, nil, []}
  def stale(x), do: stale(Macro.expand(x, __ENV__))

  # O1 (Config.config/3 shape): Process.put/2 returns
  # dynamic(not :undefined), which is not top-only but near-top.
  @spec put_setting(atom(), term()) :: keyword()
  def put_setting(key, value) when is_atom(key), do: Process.put(key, value)

  # A redundant clause (the compiler warns "the following clause is
  # redundant"): (:x) is covered by the atom() clause before it, so no
  # in-spec input reaches its :error return. Clause reachability blocks the
  # clause conflict (DESIGN 3.1 step 7).
  alias SpecLint.Fixtures.Shadow
  require Shadow
  @spec shadowed(atom()) :: :ok
  def shadowed(a) when is_atom(a), do: :ok
  Shadow.redundant_clause(:shadowed)

  # F1 refinement: the pid() of {:ok, pid(), :b} comes from subtracting the
  # spec, but :b comes from the code, so the component still counts.
  @spec narrowed_payload(atom(), term()) :: {:ok, pid(), :a}
  def narrowed_payload(x, y) when is_atom(x),
    do: if(x == :q, do: {:ok, y, :a}, else: {:ok, y, :b})

  # O3: the extra {:error, term()} is structured and present in the clause
  # return, but the clause return is gradual (Process.get/1 is dynamic()).
  @spec gradual_payload(atom()) :: {:ok, atom()}
  def gradual_payload(a) when is_atom(a) do
    case a do
      :ok -> {:ok, a}
      _ -> {:error, Process.get(a)}
    end
  end
end

defmodule SpecLint.ExperimentFixtures do
  @moduledoc false
  # Expected SL002 evidence per fixture function (DESIGN.md 11, item 1).
  #
  # For each MFA:
  #   * class     - expected function-level class from
  #                 SpecLint.Evidence.classify_function/2;
  #   * static_class - expected class with require_static_return: true,
  #                 when it differs from class;
  #   * slices    - expected per-slice classes, when there are several;
  #   * omission? - ground truth: the spec really omits a return the
  #                 function produces for inputs inside the spec domain;
  #   * note      - why.
  #
  # The experiment runner (bench/experiment.exs) reads expected/0 to report
  # fixture accuracy and the warn/no-warn decision per fixture.

  alias SpecLint.ExperimentFixtures.Cases

  @expected %{
    {Cases, :lookup, 1} => %{
      class: :clause_conflict,
      omission?: true,
      note:
        "true omission, tagged tuple {:error, :missing}: the (:missing) clause is " <>
          "contained and its whole return is outside the spec (union level: " <>
          "structured_possible)"
    },
    {Cases, :status, 1} => %{
      class: :structured_possible,
      omission?: true,
      note: "true omission, atom :timeout"
    },
    {Cases, :size_of, 1} => %{
      class: :clause_conflict,
      static_class: :possible_gradual,
      omission?: true,
      note:
        "true omission, whole kind: spec integer(), body also returns binary(); the " <>
          "second clause returns only binary() (union level: whole_kind_possible); its " <>
          "return is gradual (Atom.to_string/1)"
    },
    {Cases, :name, 1} => %{
      class: :none,
      omission?: false,
      note:
        "defensive catch-all clause returning nil for inputs outside atom(): the " <>
          "compiler makes clause domains disjoint, so the nil clause never applies"
    },
    {Cases, :display, 1} => %{
      class: :possible_domain_escape,
      omission?: false,
      note:
        "defensive catch-all inside one clause (case): nil only for inputs outside " <>
          "atom(), but the clause domain term() escapes the spec domain"
    },
    {Cases, :sign, 1} => %{
      class: :possible_input_approximate,
      omission?: false,
      note: "pos_integer() erased to integer(); :nonpositive only for n <= 0"
    },
    {Cases, :decode, 1} => %{
      class: :unknown,
      omission?: false,
      note: "delegation to an Erlang BIF: top-only inference"
    },
    {Cases, :kind, 1} => %{
      class: :possible_domain_escape,
      omission?: false,
      note: "incomparable domains: spec atom() | binary(), clause atom() | integer()"
    },
    {Cases, :pick, 1} => %{
      class: :clause_conflict,
      slices: [:clause_conflict, :none],
      omission?: false,
      note:
        "overlapping overload specs: under the union reading :special is allowed for " <>
          ":special; the class alone is a false positive (the (:special) clause is a " <>
          "clause conflict of the first slice), the overlap tag must block it"
    },
    {Cases, :wide, 1} => %{
      class: :none,
      omission?: false,
      note: "deliberately wide spec: more alternatives than inference"
    },
    {Cases, :fail!, 1} => %{
      class: :none,
      omission?: false,
      note: "no_return() spec, body always raises: no normal return predicted"
    },
    {Cases, :find_key, 2} => %{
      class: :unknown,
      omission?: false,
      note: "recursion: the recursive clause returns dynamic(), so inference is top-only"
    },
    {Cases, :count, 1} => %{
      class: :possible_domain_escape,
      omission?: false,
      note:
        "recursion through arithmetic: 1 + dynamic() is integer() | float(), so " <>
          "float() is a whole-kind false positive; the clause matching improper " <>
          "lists escapes the spec domain, so the class is possible_domain_escape (O6)"
    },
    {Cases, :wrap, 1} => %{
      class: :none,
      omission?: false,
      note:
        "helper called outside its domain: the helper's guard narrows the inferred " <>
          "domain to binary(), so the spec slice is rejected (badapply, SL003) and " <>
          "there is no extra return"
    },
    {Cases, :secret, 1} => %{
      class: :none,
      omission?: true,
      note: "opaque remote type in the return is term() as upper bound: omission hidden"
    },
    {Cases, :point, 1} => %{
      class: :structured_possible,
      static_class: :possible_gradual,
      omission?: true,
      note: "struct return spec; body also returns :origin"
    },
    {Cases, :fetch, 1} => %{
      class: :structured_possible,
      static_class: :possible_gradual,
      omission?: true,
      note: "true omission of a struct: %Point{} is structured"
    },
    {Cases, :labels, 1} => %{
      class: :clause_conflict,
      omission?: true,
      note:
        "true omission, list whose elements are structured ([:two]); the (:two) " <>
          "clause returns only [:two] (union level: structured_possible)"
    },
    {Cases, :wrap_error, 1} => %{
      class: :unknown,
      omission?: false,
      note:
        "payload widening: the private helper's return {:error, term()} does not keep " <>
          "the caller's atom(); the tag :error is already in the spec, and the payload " <>
          "not atom() exists only because the spec was subtracted (subtraction_payload?)"
    },
    {Cases, :passthrough, 1} => %{
      class: :unknown,
      omission?: true,
      note: "tuple() minus {:ok, integer()} is a negation: unknown, not reported"
    },
    {Cases, :stale, 1} => %{
      class: :clause_conflict,
      static_class: :possible_gradual,
      omission?: true,
      note:
        "stale spec hidden by a top-only union (O2): the recursive clause returns " <>
          "dynamic(), the atom and binary clauses return 5-tuples against a 4-tuple " <>
          "spec; those clause returns are gradual"
    },
    {Cases, :put_setting, 2} => %{
      class: :unknown,
      omission?: false,
      note:
        "near-top inference (O1): Process.put/2 returns dynamic(not :undefined), which " <>
          "is treated like top-only (reason near_top), not as whole-kind evidence"
    },
    {Cases, :shadowed, 1} => %{
      class: :clause_conflict,
      omission?: false,
      note:
        "redundant clause: (:x) is covered by the atom() clause before it, so every " <>
          "in-spec input returns :ok; the class is clause_conflict, and the reachability " <>
          "prerequisite (clause possibly shadowed) blocks the SL001 gate"
    },
    {Cases, :narrowed_payload, 2} => %{
      class: :structured_possible,
      static_class: :possible_gradual,
      omission?: true,
      note:
        "true omission of the :b tag under {:ok, pid(), :a}: the pid() payload of " <>
          "{:ok, pid(), :b} comes from subtracting the spec, but widening it back to " <>
          "term() still leaves the component outside the spec, so it is not a " <>
          "subtraction artefact (F1 refinement)"
    },
    {Cases, :gradual_payload, 1} => %{
      class: :structured_possible,
      static_class: :possible_gradual,
      omission?: true,
      note:
        "true omission of {:error, _} whose only witness is a gradual clause return " <>
          "(payload_gradual, O3)"
    }
  }

  @doc false
  @spec expected() :: %{mfa() => map()}
  def expected, do: @expected
end
