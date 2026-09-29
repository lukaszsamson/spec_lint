# Direct, side-effect-free witnesses from the pinned Ash holdout. The input
# values and output predicates are independent of SpecLint's translator.
#
#   elixir bench/corpus/holdout_witnesses.exs /tmp/spec-lint-expansion

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

false_page = Ash.Page.page_opts(false)
nil_page = Ash.Page.page_opts(nil)
ok_load = Ash.load(:ok, nil)
ok_refute = Ash.Test.refute_has_error(:ok, Ash.Error.Invalid, fn _ -> false end)

unless false_page == {:ok, false} and nil_page == {:ok, nil} and
         ok_load == {:ok, :ok} and ok_refute == :ok do
  raise "a pinned Ash witness changed"
end

IO.puts(
  JSON.encode!(%{
    schema: "spec_lint/holdout_witnesses",
    ash_revision: String.trim(revision),
    observations: [
      %{mfa: "Ash.Page.page_opts/1", input: "false", result: inspect(false_page)},
      %{mfa: "Ash.Page.page_opts/1", input: "nil", result: inspect(nil_page)},
      %{mfa: "Ash.load/3", input: "(:ok, nil, [])", result: inspect(ok_load)},
      %{
        mfa: "Ash.Test.refute_has_error/3",
        input: "(:ok, Ash.Error.Invalid, fn _ -> false end)",
        result: inspect(ok_refute)
      }
    ]
  })
)
