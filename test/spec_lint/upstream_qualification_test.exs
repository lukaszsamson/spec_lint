defmodule SpecLint.UpstreamQualificationTest do
  # Milestone 2: qualification of upstream Elixir 648b2a9 next to the fork
  # revision c24c235 (bench/corpus/toolchain/). The differences found are
  # pinned here as observed, per revision, so a change in either compiler
  # or in the recorded replay turns the suite red.
  use ExUnit.Case, async: true

  import SpecLint.TestHelpers

  alias SpecLint.{Beam, Compiler, Config, Issue, Project, Run}

  @moduletag :tmp_dir

  @reports Path.expand("../../bench/corpus/reports", __DIR__)
  @corpora ~w(stdlib jason decimal nimble_options mime plug ecto req broadway oban
              phoenix_live_view ash nx absinthe tesla)

  describe "for-comprehension into: a bitstring-or-list collectable (audit row 19)" do
    # c24c235 carries the fork fix "Fix incorrect narrowing in mixed type for
    # into"; upstream 648b2a9 does not (1.20.4 does not narrow either).
    # Upstream narrows a variable used as the comprehension body to
    # bitstring(), although the list path accepts any element, and stores
    # that narrowed domain in the checker chunk.
    @source """
    defmodule IntoProbe do
      @spec f(boolean(), atom()) :: atom()
      def f(flag, value) do
        into = if flag, do: [], else: ""
        _ = for _ <- [1], do: value, into: into
        value
      end
    end
    """

    test "the stored signature and the SpecLint verdict, per qualified revision",
         %{tmp_dir: dir} do
      ebin = elixirc!(dir, @source)

      # Runtime witness: the function accepts an atom and returns it.
      {witness, 0} =
        System.cmd(System.find_executable("elixir"), [
          "-pa",
          ebin,
          "-e",
          "IO.write(inspect(IntoProbe.f(true, :ok)))"
        ])

      assert witness == ":ok"

      {:ok, %Beam{exck: {:ok, chunk}}} = Beam.read(Path.join(ebin, "Elixir.IntoProbe.beam"))
      assert %{sig: {:infer, _domain, [{[flag, value], _return}]}} = chunk.exports[{:f, 2}]
      assert Compiler.equal?(flag, Compiler.term())

      project = Project.from_ebins([{:into_probe, ebin}], dir)
      {:ok, run} = Run.execute(project, %Config{baseline: "missing.json"}, ci: true)

      case String.slice(System.build_info()[:revision], 0, 7) do
        "c24c235" ->
          assert Compiler.equal?(value, Compiler.term())
          assert run.issues == []
          assert run.exit_code == 0

        "648b2a9" ->
          # Unsound: :ok is accepted at runtime but outside the stored
          # domain. SpecLint then gates a correct spec (a false positive
          # caused by the compiler, recorded in UPSTREAM_BUGS.txt).
          assert Compiler.equal?(value, Compiler.bitstring())
          assert [%Issue{rule: "SL003", gate: true}] = run.issues
          assert run.exit_code == 1

        "759443e" ->
          # Elixir 1.20.4 (Milestone 3, audit-1.20.4.md row 19): no
          # narrowing, as on the fork revision.
          assert Compiler.equal?(value, Compiler.term())
          assert run.issues == []
          assert run.exit_code == 0
      end
    end
  end

  describe "fifteen-corpus replay under 648b2a9 against the c24c235 replay" do
    test "only the adapter and the BEAM identities differ" do
      for corpus <- @corpora do
        upstream = report("upstream-648b2a9", corpus)
        fork = report("m1_review", corpus)

        assert upstream["adapter"] == "1.21.0-dev+648b2a9", corpus
        assert fork["adapter"] == "1.21.0-dev+c24c235", corpus

        assert Map.drop(upstream, ["adapter", "beams"]) == Map.drop(fork, ["adapter", "beams"]),
               "#{corpus}: report differs beyond adapter and beams"

        assert Enum.map(upstream["beams"], & &1["module"]) ==
                 Enum.map(fork["beams"], & &1["module"]),
               corpus
      end
    end

    test "every BEAM whose code differs is accounted for" do
      # stdlib: the build root embedded in literals (use macros quoted with
      # location: :keep, __ENV__.file), System (build revision and date),
      # and the two modules whose source changed. ash, nx and
      # phoenix_live_view: modules that differ between two builds with the
      # same compiler too (nondeterministic compilation, checked by
      # rebuilding them with c24c235); their stored signatures are
      # unchanged or semantically equal.
      expected = %{
        "stdlib" =>
          ~w(Agent Application DynamicSupervisor GenEvent GenServer IO Mix.Tasks.Escript.Build
             Mix.Tasks.Help Mix.Tasks.Source Module Module.Types.Apply Module.Types.Expr
             Supervisor System Task),
        "ash" => ~w(Ash.Test.Support.PolicyField.Post Ash.Test.Support.PolicyField.Ticket
             Ash.Test.Support.PolicyField.User),
        "nx" => ~w(Nx.Defn.Kernel),
        "phoenix_live_view" =>
          ~w(Phoenix.Component HealthyLive HighFrequencyStreamAndNoStreamUpdatesLive
             SameChildLive ShuffleLive StreamAsyncLive StreamAsyncLive.LC StreamComponent
             StreamInsideForLive StreamLimitLive StreamLive
             StreamNestedComponentResetLive StreamNestedComponentResetLive.InnerComponent
             StreamResetLCLive StreamResetLive ThermostatLive UploadComponent UploadLive
             UploadLiveWithComponent WithComponentLive WithMultipleTargets)
          |> Enum.map(fn
            "Phoenix.Component" = module -> module
            name -> "Phoenix.LiveViewTest.Support." <> name
          end)
      }

      for corpus <- @corpora do
        fork = Map.new(report("m1_review", corpus)["beams"], &{&1["module"], &1["md5"]})

        differing =
          for %{"module" => module, "md5" => md5} <- report("upstream-648b2a9", corpus)["beams"],
              md5 != fork[module],
              do: module

        assert Enum.sort(differing) == Enum.sort(Map.get(expected, corpus, [])), corpus
      end
    end
  end

  defp report(dir, corpus),
    do:
      [@reports, dir, corpus <> ".spec_lint.json"]
      |> Path.join()
      |> File.read!()
      |> JSON.decode!()
end
