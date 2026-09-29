# Prints the pinned compiler module digests of the running Elixir build
# (SpecLint.Compiler.BuildIdentity) as the Elixir map entry the adapter's
# @qualified_builds attribute holds for one revision:
#
#     /path/to/elixir/bin/elixir bench/corpus/toolchain/pinned_digests.exs
#
# Needs only the running build and this checkout. Writes nothing.

root = Path.expand("../../..", __DIR__)
Code.put_compiler_option(:no_warn_undefined, :all)
Code.require_file(Path.join(root, "lib/spec_lint/beam.ex"))
Code.require_file(Path.join(root, "lib/spec_lint/compiler/build_identity.ex"))

alias SpecLint.Compiler.BuildIdentity

{:ok, digests} = BuildIdentity.digests(BuildIdentity.running_ebins())
revision = System.build_info()[:revision]

IO.puts(~s(  "#{revision}" => %{))

digests
|> Enum.sort()
|> Enum.map_join(",\n", fn {module, digest} -> ~s(    "#{module}" =>\n      "#{digest}") end)
|> IO.puts()

IO.puts("  }")
IO.puts(:stderr, "#{map_size(digests)} modules, build digest #{BuildIdentity.combined(digests)}")
