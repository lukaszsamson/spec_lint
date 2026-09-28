defmodule SpecLint.Rules.SpecDomainBodyWarning do
  @moduledoc """
  `SL007 spec_domain_body_warning` (DESIGN.md sections 4 and 7).

  Requires the body analysis backend, which no qualified build provides
  yet, so the rule is unavailable: `available?/0` is `false`, it is off by
  default, and requesting it (`--rules SL007` or `analysis: :bodies`) is a
  capability error, never a silent fallback.
  """

  @behaviour SpecLint.Rule

  @impl true
  @spec id() :: String.t()
  def id, do: "SL007"

  @impl true
  @spec name() :: :spec_domain_body_warning
  def name, do: :spec_domain_body_warning

  @impl true
  @spec default_severity() :: :off
  def default_severity, do: :off

  @impl true
  @spec summary() :: String.t()
  def summary, do: "checker diagnostic under the spec assumption (body backend, unavailable)"

  @impl true
  @spec available?() :: false
  def available?, do: false

  @impl true
  @spec check_function(SpecLint.Rule.function_context()) :: []
  def check_function(_context), do: []

  @impl true
  @spec check_module(SpecLint.Rule.module_context()) :: []
  def check_module(_context), do: []
end
