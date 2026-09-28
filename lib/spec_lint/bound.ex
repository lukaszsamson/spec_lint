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

  @typedoc "A non-loss label."
  @type note :: %{kind: :opaque_expanded | :nominal_expanded, path: [segment()]}

  @type t :: %__MODULE__{
          lo: Compiler.descr(),
          hi: Compiler.descr(),
          losses: [loss()],
          notes: [note()]
        }

  @enforce_keys [:lo, :hi]
  defstruct [:lo, :hi, losses: [], notes: []]

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
end
