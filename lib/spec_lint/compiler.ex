defmodule SpecLint.Compiler do
  @moduledoc """
  Compiler adapter boundary.

  Everything SpecLint needs from the Elixir compiler's internals goes through
  this module: decoding the `ExCk` checker chunk, every
  `Module.Types.Descr` operation, and a copy of the checker's application rule
  for inferred signatures (`Module.Types.Apply.apply_infer/2`). All of those
  are `@moduledoc false` in Elixir and change between development revisions,
  so one adapter module exists per qualified compiler revision (see
  `SpecLint.Compiler.V121`) and the rest of SpecLint never touches compiler
  modules directly.

  This module defines the adapter behaviour and a facade that delegates to
  the adapter returned by `adapter/0`. The adapter is read at runtime, on
  every call, from the `:compiler_adapter` setting of the `:spec_lint`
  application and defaults to `SpecLint.Compiler.V121`; `preflight/0` checks
  that it is qualified for the running compiler. Descr values are treated
  as opaque terms outside the adapter; printed forms are presentation only.
  """

  @typedoc "A `Module.Types.Descr` type. Opaque outside the adapter."
  @type descr :: :term | map()

  @typedoc "One inferred clause as stored in the checker chunk: argument types and return."
  @type clause :: {[descr()], descr()}

  @typedoc "A signature as stored in the checker chunk."
  @type sig :: {:infer, descr() | nil, [clause()]} | {:strong, descr() | nil, [clause()]} | :none

  @typedoc "Decoded contents of an `ExCk` chunk."
  @type chunk :: %{
          version: atom(),
          mode: atom(),
          exports: %{optional({atom(), arity()}) => %{sig: sig(), deprecated: term()}}
        }

  @typedoc "Reasons a checker chunk cannot be decoded."
  @type chunk_error ::
          {:checker_version_mismatch, found :: term(), expected :: atom()}
          | {:unqualified_checker_version, running :: atom(), qualified :: atom()}
          | :malformed_chunk

  @typedoc """
  Result of applying an inferred signature: `{used_clause_indexes, return}`
  (indexes in the compiler's order, which is reverse clause order), or
  `:error` when no clause applies (the checker would report `badremote`).
  """
  @type application :: {[non_neg_integer()], descr()} | :error

  @typedoc "Capability report returned by `preflight/0`."
  @type capabilities :: %{
          adapter: module(),
          adapter_id: String.t(),
          elixir_version: String.t(),
          revision: String.t() | nil,
          otp_release: String.t(),
          checker_version: atom(),
          max_clauses: pos_integer(),
          signatures: boolean(),
          body_hook: boolean()
        }

  @typedoc "Base kinds usable as non-literal map key domains."
  @type key_kind ::
          :binary
          | :bitstring_no_binary
          | :integer
          | :float
          | :pid
          | :port
          | :reference
          | :fun
          | :atom
          | :tuple
          | :map
          | :list

  @typedoc "A literal atom map field: key, value type and whether it is optional."
  @type map_field :: {atom(), descr(), boolean()}

  @typedoc "A non-literal map key domain: the key kinds and the value type."
  @type map_domain :: {[key_kind()], descr()}

  @typedoc """
  A base kind of the lattice, as seen by `components/1`. `:list` covers
  both the empty list and non-empty lists.
  """
  @type kind ::
          :atom
          | :integer
          | :float
          | :binary
          | :bitstring_no_binary
          | :pid
          | :port
          | :reference
          | :tuple
          | :map
          | :list
          | :fun

  @typedoc """
  Structural view of one component of a type (see `components/1`):

    * `{:whole, kind}` - the entire base kind;
    * `{:atoms, atoms}` - a finite, non-empty set of atoms (sorted);
    * `:empty_list` - only `[]`;
    * `{:tuple, :closed | :open, elements}` - one tuple literal with no
      remaining negation (`:open` means "at least these elements");
    * `{:map, :closed | :open, fields, domains}` - one map literal with no
      remaining negation;
    * `{:list, element, tail, empty?}` - non-empty lists of `element`
      ending in `tail`, plus `[]` when `empty?`;
    * `{:unknown, kind, reason}` - a component the adapter cannot present
      as a single literal: `:negation` (a negation that could not be
      eliminated), `:intersection` (several positive literals) or `:shape`
      (for example a function type other than `fun()`).
  """
  @type view ::
          {:whole, kind()}
          | {:atoms, [atom(), ...]}
          | :empty_list
          | {:tuple, :closed | :open, [descr()]}
          | {:map, :closed | :open, [map_field()], [map_domain()]}
          | {:list, descr(), descr(), boolean()}
          | {:unknown, kind(), :negation | :intersection | :shape}

  @typedoc "One component of a type: its kind, its own type and its view."
  @type component :: %{kind: kind(), descr: descr(), view: view()}

  @doc "Checks the running compiler and reports what this adapter can do."
  @callback preflight() :: {:ok, capabilities()} | {:error, term()}

  @doc "The checker chunk version this adapter is qualified for."
  @callback qualified_checker_version() :: atom()

  @doc "Decodes the raw bytes of an `ExCk` chunk."
  @callback decode_checker_chunk(binary()) :: {:ok, chunk()} | {:error, chunk_error()}

  @doc "Faithful copy of `Module.Types.Apply.apply_infer/2`."
  @callback apply_infer([clause()], [descr()]) :: application()

  @doc "The clause cutoff used by the application rule."
  @callback max_clauses() :: pos_integer()

  @doc "The empty type."
  @callback none() :: descr()
  @doc "The top type."
  @callback term() :: descr()
  @doc "The top gradual type."
  @callback dynamic() :: descr()
  @doc "Wraps a type in `dynamic()`."
  @callback dynamic(descr()) :: descr()
  @doc "All atoms."
  @callback atom() :: descr()
  @doc "A finite set of atoms."
  @callback atom([atom()]) :: descr()
  @doc "All integers."
  @callback integer() :: descr()
  @doc "All floats."
  @callback float() :: descr()
  @doc "All binaries."
  @callback binary() :: descr()
  @doc "All bitstrings."
  @callback bitstring() :: descr()
  @doc "Bitstrings that are not binaries."
  @callback bitstring_no_binary() :: descr()
  @doc "All pids."
  @callback pid() :: descr()
  @doc "All ports."
  @callback port() :: descr()
  @doc "All references."
  @callback reference() :: descr()
  @doc "`true | false`."
  @callback boolean() :: descr()
  @doc "The empty list."
  @callback empty_list() :: descr()
  @doc "Proper lists (including `[]`) of the given element type."
  @callback list(descr()) :: descr()
  @doc "Non-empty lists with the given element and tail type."
  @callback non_empty_list(descr(), descr()) :: descr()
  @doc "All tuples."
  @callback tuple() :: descr()
  @doc "Closed tuples with the given element types."
  @callback tuple([descr()]) :: descr()
  @doc "Tuples starting with the given element types, of any greater size."
  @callback open_tuple([descr()]) :: descr()
  @doc "The empty map."
  @callback empty_map() :: descr()
  @doc "All maps."
  @callback open_map() :: descr()
  @doc "A closed map with literal atom fields and non-literal key domains."
  @callback closed_map([map_field()], [map_domain()]) :: descr()
  @doc "All functions."
  @callback fun() :: descr()
  @doc "All functions of the given arity."
  @callback fun(arity()) :: descr()
  @doc "The function type from arguments to return."
  @callback fun([descr()], descr()) :: descr()
  @doc "Set union."
  @callback union(descr(), descr()) :: descr()
  @doc "Set intersection."
  @callback intersection(descr(), descr()) :: descr()
  @doc "Set difference."
  @callback difference(descr(), descr()) :: descr()
  @doc "Gradual subtyping."
  @callback subtype?(descr(), descr()) :: boolean()
  @doc "Whether two types share no value."
  @callback disjoint?(descr(), descr()) :: boolean()
  @doc "Whether a type has no value."
  @callback empty?(descr()) :: boolean()
  @doc "Semantic type equality."
  @callback equal?(descr(), descr()) :: boolean()
  @doc "Whether a type has a `dynamic()` component."
  @callback gradual?(descr()) :: boolean()
  @doc "Upper bound of a gradual type."
  @callback upper_bound(descr()) :: descr()
  @doc "Lower bound (static part) of a gradual type."
  @callback lower_bound(descr()) :: descr()
  @doc "Presentation string of a type."
  @callback to_string(descr()) :: String.t()
  @doc "Finite atom set of a type, if its atom component is finite."
  @callback atom_fetch(descr()) :: {:finite, [atom()]} | {:infinite, [atom()]} | :error
  @doc "Base kinds a map key type touches; a finite atom component counts as `:atom`."
  @callback key_kinds(descr()) :: [key_kind()]
  @doc "The whole base kind for a map key kind."
  @callback key_kind_descr(key_kind()) :: descr()
  @doc "Splits the upper bound of a type into per-kind components."
  @callback components(descr()) :: [component()]
  @doc """
  Canonical serialisable form of a type: a plain term with no functions,
  references or VM-specific values, equal for equal inputs in every VM.
  """
  @callback canonical(descr()) :: term()

  @typedoc """
  One pattern or guard diagnostic of the compiler's own type checker: the
  function it was reported in and its line (`nil` when the metadata has
  none).
  """
  @type pattern_diagnostic :: {{atom(), arity()}, pos_integer() | nil}

  @doc """
  Re-runs the compiler's type checker, in the mode it uses for warnings
  after compilation, over `definitions` (debug info definitions of
  `module`) and returns its pattern and guard diagnostics: a clause whose
  head cannot match, a guard that can never succeed, a redundant clause.
  `attributes` are the module's `__protocol__`/`__impl__` attributes.
  """
  @callback pattern_diagnostics(module(), String.t() | nil, keyword(), [tuple()]) ::
              {:ok, [pattern_diagnostic()]} | {:error, term()}

  @default_adapter SpecLint.Compiler.V121

  @doc """
  The adapter module in use: the `:compiler_adapter` setting of the
  `:spec_lint` application, defaulting to the adapter for the qualified
  revision. `preflight/0` checks that it matches the running compiler.
  """
  @spec adapter() :: module()
  def adapter, do: Application.get_env(:spec_lint, :compiler_adapter, @default_adapter)

  @doc "See `c:preflight/0`."
  @spec preflight() :: {:ok, capabilities()} | {:error, term()}
  def preflight, do: adapter().preflight()

  @doc """
  `preflight/0` of the current adapter, memoised per adapter for the life of
  the VM (the running compiler cannot change within a VM).
  """
  @spec preflight_once() :: {:ok, capabilities()} | {:error, term()}
  def preflight_once do
    adapter = adapter()
    key = {__MODULE__, :preflight, adapter}

    case :persistent_term.get(key, nil) do
      nil ->
        result = adapter.preflight()
        :persistent_term.put(key, result)
        result

      result ->
        result
    end
  end

  @doc "See `c:qualified_checker_version/0`."
  @spec qualified_checker_version() :: atom()
  def qualified_checker_version, do: adapter().qualified_checker_version()

  @doc "See `c:decode_checker_chunk/1`."
  @spec decode_checker_chunk(binary()) :: {:ok, chunk()} | {:error, chunk_error()}
  def decode_checker_chunk(bytes), do: adapter().decode_checker_chunk(bytes)

  @doc "See `c:apply_infer/2`."
  @spec apply_infer([clause()], [descr()]) :: application()
  def apply_infer(clauses, args), do: adapter().apply_infer(clauses, args)

  @doc "See `c:max_clauses/0`."
  @spec max_clauses() :: pos_integer()
  def max_clauses, do: adapter().max_clauses()

  @doc "The empty type."
  @spec none() :: descr()
  def none, do: adapter().none()

  @doc "The top type."
  @spec term() :: descr()
  def term, do: adapter().term()

  @doc "The top gradual type."
  @spec dynamic() :: descr()
  def dynamic, do: adapter().dynamic()

  @doc "Wraps a type in `dynamic()`."
  @spec dynamic(descr()) :: descr()
  def dynamic(descr), do: adapter().dynamic(descr)

  @doc "All atoms."
  @spec atom() :: descr()
  def atom, do: adapter().atom()

  @doc "A finite set of atoms."
  @spec atom([atom()]) :: descr()
  def atom(atoms), do: adapter().atom(atoms)

  @doc "All integers."
  @spec integer() :: descr()
  def integer, do: adapter().integer()

  @doc "All floats."
  @spec float() :: descr()
  def float, do: adapter().float()

  @doc "All binaries."
  @spec binary() :: descr()
  def binary, do: adapter().binary()

  @doc "All bitstrings."
  @spec bitstring() :: descr()
  def bitstring, do: adapter().bitstring()

  @doc "Bitstrings that are not binaries."
  @spec bitstring_no_binary() :: descr()
  def bitstring_no_binary, do: adapter().bitstring_no_binary()

  @doc "All pids."
  @spec pid() :: descr()
  def pid, do: adapter().pid()

  @doc "All ports."
  @spec port() :: descr()
  def port, do: adapter().port()

  @doc "All references."
  @spec reference() :: descr()
  def reference, do: adapter().reference()

  @doc "`true | false`."
  @spec boolean() :: descr()
  def boolean, do: adapter().boolean()

  @doc "The empty list."
  @spec empty_list() :: descr()
  def empty_list, do: adapter().empty_list()

  @doc "Proper lists (including `[]`) of the given element type."
  @spec list(descr()) :: descr()
  def list(elem), do: adapter().list(elem)

  @doc "Non-empty lists with the given element and tail type."
  @spec non_empty_list(descr(), descr()) :: descr()
  def non_empty_list(elem, tail), do: adapter().non_empty_list(elem, tail)

  @doc "All tuples."
  @spec tuple() :: descr()
  def tuple, do: adapter().tuple()

  @doc "Closed tuples with the given element types."
  @spec tuple([descr()]) :: descr()
  def tuple(elems), do: adapter().tuple(elems)

  @doc "Tuples starting with the given element types, of any greater size."
  @spec open_tuple([descr()]) :: descr()
  def open_tuple(elems), do: adapter().open_tuple(elems)

  @doc "The empty map."
  @spec empty_map() :: descr()
  def empty_map, do: adapter().empty_map()

  @doc "All maps."
  @spec open_map() :: descr()
  def open_map, do: adapter().open_map()

  @doc """
  A closed map. Literal atom `fields` take precedence over non-literal key
  `domains` for their key.
  """
  @spec closed_map([map_field()], [map_domain()]) :: descr()
  def closed_map(fields, domains), do: adapter().closed_map(fields, domains)

  @doc "All functions."
  @spec fun() :: descr()
  def fun, do: adapter().fun()

  @doc "All functions of the given arity (`(none(), ... -> term())`)."
  @spec fun(arity()) :: descr()
  def fun(arity), do: adapter().fun(arity)

  @doc "The function type from `args` to `return`."
  @spec fun([descr()], descr()) :: descr()
  def fun(args, return), do: adapter().fun(args, return)

  @doc "Set union."
  @spec union(descr(), descr()) :: descr()
  def union(left, right), do: adapter().union(left, right)

  @doc "Union of a list of types (`none()` for the empty list)."
  @spec union_all([descr()]) :: descr()
  def union_all(descrs), do: Enum.reduce(descrs, none(), &union(&2, &1))

  @doc "Set intersection."
  @spec intersection(descr(), descr()) :: descr()
  def intersection(left, right), do: adapter().intersection(left, right)

  @doc "Set difference."
  @spec difference(descr(), descr()) :: descr()
  def difference(left, right), do: adapter().difference(left, right)

  @doc "Gradual subtyping."
  @spec subtype?(descr(), descr()) :: boolean()
  def subtype?(left, right), do: adapter().subtype?(left, right)

  @doc "Whether two types share no value."
  @spec disjoint?(descr(), descr()) :: boolean()
  def disjoint?(left, right), do: adapter().disjoint?(left, right)

  @doc "Whether a type has no value."
  @spec empty?(descr()) :: boolean()
  def empty?(descr), do: adapter().empty?(descr)

  @doc "Semantic type equality."
  @spec equal?(descr(), descr()) :: boolean()
  def equal?(left, right), do: adapter().equal?(left, right)

  @doc "Whether a type has a `dynamic()` component."
  @spec gradual?(descr()) :: boolean()
  def gradual?(descr), do: adapter().gradual?(descr)

  @doc "Upper bound of a gradual type."
  @spec upper_bound(descr()) :: descr()
  def upper_bound(descr), do: adapter().upper_bound(descr)

  @doc "Lower bound (static part) of a gradual type."
  @spec lower_bound(descr()) :: descr()
  def lower_bound(descr), do: adapter().lower_bound(descr)

  @doc "Presentation string of a type. Never parse or compare it."
  @spec to_string(descr()) :: String.t()
  def to_string(descr), do: adapter().to_string(descr)

  @doc "Finite atom set of a type, if its atom component is finite."
  @spec atom_fetch(descr()) :: {:finite, [atom()]} | {:infinite, [atom()]} | :error
  def atom_fetch(descr), do: adapter().atom_fetch(descr)

  @doc """
  Base kinds a map key type touches. A finite atom component counts as the
  atom kind, so the kinds always cover the key.
  """
  @spec key_kinds(descr()) :: [key_kind()]
  def key_kinds(descr), do: adapter().key_kinds(descr)

  @doc "The whole base kind for a map key kind."
  @spec key_kind_descr(key_kind()) :: descr()
  def key_kind_descr(kind), do: adapter().key_kind_descr(kind)

  @doc """
  Splits the upper bound of `descr` into components, one per base kind
  and, within tuples, maps and lists, one per literal of its normal form.
  The union of the components' `descr` is the upper bound of `descr`.

  Order is deterministic: bit kinds, atoms, tuples, maps, lists, functions.
  Negations the adapter can eliminate soundly are eliminated (negative
  literals disjoint from the positive one; for closed tuples, negative
  tuples of the same arity by splitting on the first differing element);
  anything else is reported as `{:unknown, kind, reason}` rather than
  guessed.
  """
  @spec components(descr()) :: [component()]
  def components(descr), do: adapter().components(descr)

  @doc """
  Canonical serialisable form of `descr` for fingerprints (DESIGN.md
  section 9): a plain term with no functions, references or VM-specific
  values, so `:erlang.term_to_binary(canonical, [:deterministic])` is the
  same for the same type in every VM. It is structural, not semantic: two
  representations of the same set may differ. Never compare it for
  subtyping; use it only to detect that stored evidence changed.
  """
  @spec canonical(descr()) :: term()
  def canonical(descr), do: adapter().canonical(descr)

  @doc "See `c:pattern_diagnostics/4`."
  @spec pattern_diagnostics(module(), String.t() | nil, keyword(), [tuple()]) ::
          {:ok, [pattern_diagnostic()]} | {:error, term()}
  def pattern_diagnostics(module, file, attributes, definitions),
    do: adapter().pattern_diagnostics(module, file, attributes, definitions)
end
