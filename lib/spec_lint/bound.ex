defmodule SpecLint.Bound do
  @moduledoc """
  Translation bounds for one typespec node.

  `lo` and `hi` are `Module.Types.Descr` types (through `SpecLint.Compiler`)
  with `lo ⊆ S ⊆ hi` for the set `S` the typespec denotes. Every inexact
  translation carries at least one loss record; a bound without losses is
  exact and has `lo == hi`.

  Loss kinds are the ones listed in DESIGN.md section 6, plus
  `:map_key_widened` for a non-literal map key that cannot be expressed
  exactly (section 6 requires recording a loss for it but names no kind).
  Paths locate the loss in the spec slice: `{:arg, index}` or `:return`
  first, then one segment per constructor or named type traversed.

  `notes` carries labels that are not losses, such as structural expansion of
  another module's opaque type when `expand_opaque: true` was requested.

  `integers` keeps what the lattice cannot express about the integers of `S`
  (it has no integer literals or ranges): `nil` when nothing is known beyond
  `hi`, otherwise a list of closed intervals whose union contains every
  integer of `S` (`S ∩ integer() ⊆ ⋃ integers`). It is only an upper bound,
  it is kept for the top level of the node only (not inside tuples, lists or
  maps), and it never makes a bound exact: literal integers, ranges and
  refinements such as `pos_integer()` stay `integer()` in `hi` with an
  `:integer_refinement_erased` loss. `SpecLint.Compare` uses it to prove
  that two overloads with, for example, `0` and `pos_integer()` at the same
  position do not overlap.
  """

  alias SpecLint.Compiler

  @typedoc "Why a translation is not exact."
  @type loss_kind ::
          :integer_refinement_erased
          | :sized_binary_erased
          | :charlist_as_integers
          | :recursive_cutoff
          | :unresolved_remote_type
          | :opaque_boundary
          | :nominal_boundary
          | :type_variable_correlation
          | :arrow_polarity
          | :record_fields_unknown
          | :unsupported_construct
          | :map_key_widened

  @typedoc "One segment of a path into the spec's type tree."
  @type segment :: term()

  @typedoc "A loss record."
  @type loss :: %{kind: loss_kind(), path: [segment()]}

  @typedoc "An integer interval end: an integer or an unbounded end."
  @type int_end :: integer() | :neg_infinity | :infinity

  @typedoc "A closed integer interval `{first, last}`."
  @type interval :: {int_end(), int_end()}

  @typedoc "A non-loss label."
  @type note :: %{kind: :opaque_expanded | :nominal_expanded, path: [segment()]}

  @type t :: %__MODULE__{
          lo: Compiler.descr(),
          hi: Compiler.descr(),
          losses: [loss()],
          notes: [note()],
          integers: [interval()] | nil
        }

  @enforce_keys [:lo, :hi]
  defstruct [:lo, :hi, losses: [], notes: [], integers: nil]

  @doc "An exact bound: `lo == hi == descr`."
  @spec exact(Compiler.descr()) :: t()
  def exact(descr), do: %__MODULE__{lo: descr, hi: descr}

  @doc "A bound that is only an upper bound (`lo = none()`), with one loss."
  @spec upper(Compiler.descr(), loss_kind(), [segment()]) :: t()
  def upper(hi, kind, path) do
    %__MODULE__{lo: Compiler.none(), hi: hi, losses: [loss(kind, path)]}
  end

  @doc "Builds a loss record."
  @spec loss(loss_kind(), [segment()]) :: loss()
  def loss(kind, path), do: %{kind: kind, path: path}

  @doc "Whether the translation is exact (no loss records)."
  @spec exact?(t()) :: boolean()
  def exact?(%__MODULE__{losses: losses}), do: losses == []

  @doc "The distinct loss kinds of a bound, sorted."
  @spec loss_kinds(t()) :: [loss_kind()]
  def loss_kinds(%__MODULE__{losses: losses}),
    do: losses |> Enum.map(& &1.kind) |> Enum.uniq() |> Enum.sort()

  @doc """
  Combines child bounds with a covariant constructor: `build` is applied to
  the children's `lo` values and to their `hi` values; losses and notes are
  concatenated in order.
  """
  @spec map_covariant([t()], ([Compiler.descr()] -> Compiler.descr())) :: t()
  def map_covariant(children, build) do
    %__MODULE__{
      lo: build.(Enum.map(children, & &1.lo)),
      hi: build.(Enum.map(children, & &1.hi)),
      losses: Enum.flat_map(children, & &1.losses),
      notes: Enum.flat_map(children, & &1.notes)
    }
  end

  @doc "Adds a loss record."
  @spec add_loss(t(), loss_kind(), [segment()]) :: t()
  def add_loss(%__MODULE__{} = bound, kind, path),
    do: %{bound | losses: bound.losses ++ [loss(kind, path)]}

  @doc """
  Intervals that contain every integer of the bound's set: `integers` when
  known, otherwise `[]` when `hi` has no integer and the whole line when it
  has some.
  """
  @spec integer_intervals(t()) :: [interval()]
  def integer_intervals(%__MODULE__{integers: integers}) when is_list(integers), do: integers

  def integer_intervals(%__MODULE__{hi: hi}) do
    if Compiler.disjoint?(hi, Compiler.integer()), do: [], else: [{:neg_infinity, :infinity}]
  end

  @doc "Whether two interval lists share no integer."
  @spec intervals_disjoint?([interval()], [interval()]) :: boolean()
  def intervals_disjoint?(left, right) do
    Enum.all?(left, fn {first, last} ->
      Enum.all?(right, fn {other_first, other_last} ->
        before?(last, other_first) or before?(other_last, first)
      end)
    end)
  end

  # Strict order on interval ends (atoms sort after numbers in term order,
  # so the unbounded ends are handled explicitly).
  defp before?(:infinity, _right), do: false
  defp before?(_left, :neg_infinity), do: false
  defp before?(:neg_infinity, _right), do: true
  defp before?(_left, :infinity), do: true
  defp before?(left, right), do: left < right
end
