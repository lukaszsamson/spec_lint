# Run with: elixir bench/upstream/phoenix_view_override.exs
# Mix.install installs and starts public dependencies; this files no issue.
# Related prior discussion: phoenixframework/phoenix_view PR #7 and issue #8.
Mix.install([
  {:phoenix_view,
   git: "https://github.com/phoenixframework/phoenix_view.git",
   ref: "87159b55dea9f68147943f46a2996727b7d20268"},
  {:phoenix_template, "== 1.0.4"}
])

[{module, beam}] =
  Code.compile_quoted(
    quote do
      defmodule SpecLintPhoenixViewWitness do
        use Phoenix.View, root: "spec_lint_missing_templates"
        def template_not_found(_template, _assigns), do: "Not Found"
      end
    end
  )

{:ok, specs} = Code.Typespec.fetch_specs(beam)
{{:template_not_found, 2}, clauses} = List.keyfind(specs, {:template_not_found, 2}, 0)
true = Enum.any?(clauses, &match?({:type, _, :fun, [_, {:type, _, :no_return, []}]}, &1))
"Not Found" = module.template_not_found("404.html", %{})

IO.puts(
  "Confirmed: an in-domain call returns a binary while the inherited spec says no_return()."
)
