defmodule SpecLint.Integration.Release.InstallTest do
  # Milestone 5, installation workflows through the public Mix tasks, on
  # consumers created in a temporary directory: spec_lint as a path
  # dependency, as a git dependency (a snapshot repository of the working
  # tree) and in an umbrella.
  #
  #   (a) fresh install and the first run, with no baseline;
  #   (b) `mix spec_lint.baseline`, then a clean `--ci` run, and how the
  #       baseline behaves as the project changes (README "Baseline");
  #   (e) an umbrella consumer.
  #
  # Every assertion holds under each qualified compiler (1.21 upstream,
  # the fork, 1.20.4): only the compiler's own adapter id is compared.
  use ExUnit.Case, async: false

  Code.require_file("release_helper.exs", __DIR__)

  alias SpecLint.ProjectFixture, as: Fixture
  alias SpecLint.Release.Consumer, as: C

  @moduletag :integration
  @moduletag :release
  @moduletag timeout: 900_000

  defp consumer(prefix, dep, opts \\ []) do
    dir = C.create!(prefix, dep, opts)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp rm_on_exit(path) do
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  describe "path dependency" do
    test "(a) fresh install and first run with no baseline" do
      dir = consumer("install-path", C.path_dep())

      # Nothing to fetch for a path dependency.
      {output, 0} = C.mix(dir, ["deps.get"])
      refute output =~ "Getting"

      # The first run compiles the dependency and the project, and finds
      # nothing to say about a clean project: exit 0 in CI mode too, with no
      # baseline. It analysed one slice and says how much it could not
      # decide (README "What no finding means").
      {status, json, output} = C.lint(dir)
      assert status == 0, output
      assert json["adapter"] == C.adapter_id()
      assert json["findings"] == []
      assert json["baseline"]["applied"] == false
      assert json["baseline"]["path"] == ".spec_lint_baseline.json"
      assert json["completion"]["status"] == "complete"
      assert json["ledger"]["slices"]["compared"] == 1
      assert json["ledger"]["obligations"] == %{"established" => 1}
      assert json["ledger"]["obligations_unknown_by_reason"] == %{}
      refute File.exists?(C.baseline_path(dir)), "a lint run never writes the baseline"

      # The console report of the first run, without CI mode.
      {output, 0} = C.mix(dir, ["spec_lint"])
      assert output =~ "SpecLint 0.1.0 (adapter #{C.adapter_id()}"
      assert output =~ "Baseline: none (.spec_lint_baseline.json not found)"
      assert output =~ "Findings: 0 reported (none), 0 gating and new"
      assert output =~ "Result: complete, exit 0"

      # "No finding" is not "verified": a spec whose implementation is the
      # identity function gets no finding, and its obligation is counted as
      # unknown (the inferred return is as wide as the spec allows).
      Fixture.write!(dir, "lib/identity.ex", """
      defmodule Consumer.Identity do
        @spec id(atom()) :: atom()
        def id(value), do: value
      end
      """)

      {0, json, _output} = C.lint(dir)
      assert json["findings"] == []
      assert json["ledger"]["obligations"] == %{"established" => 1, "unknown" => 1}
      assert json["ledger"]["obligations_unknown_by_reason"] == %{"top_only" => 1}
      File.rm!(Path.join(dir, "lib/identity.ex"))

      # A project with gated findings: reported everywhere, failing only in
      # CI mode, and still without a baseline file.
      Fixture.write!(dir, "lib/bad.ex", C.bad_source())

      {output, 0} = C.mix(dir, ["spec_lint"])
      assert output =~ "Findings: 3 reported (SL001 3), 3 gating and new"
      assert output =~ "Result: complete, exit 0"

      {status, json, output} = C.lint(dir)
      assert status == 1, output

      assert Enum.sort(Enum.map(json["findings"], & &1["subject"])) ==
               ["Consumer.Bad.shape/1", "Consumer.Bad.size/1", "Consumer.Bad.wrap/1"]

      assert Enum.all?(json["findings"], &(&1["rule"] == "SL001" and &1["blocking"] == true))
      assert json["baseline"]["new"] == 3
      assert json["completion"]["exit_code"] == 1
      refute File.exists?(C.baseline_path(dir))

      # A baseline path that is set explicitly must exist.
      {output, 2} = C.mix(dir, ["spec_lint", "--ci", "--baseline", "missing.json"])
      assert output =~ "baseline file not found: missing.json"
      assert output =~ "create the baseline with mix spec_lint.baseline"

      # The task documents itself.
      {output, 0} = C.mix(dir, ["help", "spec_lint"])
      assert output =~ "mix spec_lint"
      assert output =~ "--ci"
    end

    test "(b) the baseline task, a clean --ci run, and the life of a baseline" do
      dir = consumer("baseline-path", C.path_dep())
      Fixture.write!(dir, "lib/bad.ex", C.bad_source())

      {status, _json, output} = C.lint(dir)
      assert status == 1, output

      # Write the baseline: the three findings and one inventory entry per
      # compared slice.
      {output, 0} = C.mix(dir, ["spec_lint.baseline"])
      assert output =~ "spec_lint.baseline: 3 finding(s), 4 inventory entries"
      baseline = C.read_baseline!(dir)
      assert baseline["version"] == 1
      assert baseline["adapter"] == C.adapter_id()
      assert length(baseline["findings"]) == 3

      assert Enum.all?(baseline["findings"], fn entry ->
               entry["adapter"] == C.adapter_id() and entry["reason"] == nil and
                 entry["owner"] == nil and entry["expires"] == nil and is_list(entry["blocked"])
             end)

      assert Enum.all?(baseline["inventory"], &(&1["status"] == "compared"))

      # The same project, the same baseline: byte-identical when written
      # again, and a clean --ci run.
      first = File.read!(C.baseline_path(dir))
      {_output, 0} = C.mix(dir, ["spec_lint.baseline"])
      assert File.read!(C.baseline_path(dir)) == first

      {status, json, output} = C.lint(dir)
      assert status == 0, output
      assert json["completion"]["exit_code"] == 0
      assert json["baseline"]["applied"] == true
      assert %{"baselined" => 3, "new" => 0, "expired" => 0} = json["baseline"]
      assert Enum.all?(json["findings"], &(&1["baseline"] == "baselined" and not &1["blocking"]))

      {output, 0} = C.mix(dir, ["spec_lint", "--ci"])
      assert output =~ "Result: complete, exit 0"

      # A new finding fails the build; the acknowledged ones do not.
      Fixture.write!(dir, "lib/worse.ex", C.worse_source())
      {status, json, output} = C.lint(dir)
      assert status == 1, output
      assert [%{"subject" => "Consumer.Worse.label/1", "blocking" => true}] = blocking(json)
      assert json["baseline"]["baselined"] == 3

      # Reconciliation: review, then regenerate. Reason, owner and expiry
      # written by hand survive it.
      {_output, 0} = C.mix(dir, ["spec_lint.baseline"])

      annotate!(dir, "Consumer.Bad.size/1", %{
        "reason" => "returns the atom on purpose",
        "owner" => "team-a",
        "expires" => "2999-12-31"
      })

      {_output, 0} = C.mix(dir, ["spec_lint.baseline"])

      assert %{
               "reason" => "returns the atom on purpose",
               "owner" => "team-a",
               "expires" => "2999-12-31"
             } =
               entry!(dir, "Consumer.Bad.size/1")

      {0, _json, _output} = C.lint(dir)

      # An acknowledgement past its expiry date counts as new.
      annotate!(dir, "Consumer.Bad.size/1", %{"expires" => "2000-01-01"})
      {status, json, output} = C.lint(dir)
      assert status == 1, output
      assert json["baseline"]["expired"] == 1
      assert [%{"subject" => "Consumer.Bad.size/1", "baseline" => "expired"}] = blocking(json)

      # A malformed date is an invalid baseline, never an acknowledgement
      # that lasts forever.
      annotate!(dir, "Consumer.Bad.size/1", %{"expires" => "someday"})
      {output, 2} = C.mix(dir, ["spec_lint", "--ci"])
      assert output =~ "invalid baseline"
      annotate!(dir, "Consumer.Bad.size/1", %{"expires" => "2999-12-31"})

      # Fixing a finding leaves its entry stale: a warning, still exit 0;
      # regenerating drops it.
      Fixture.write!(
        dir,
        "lib/bad.ex",
        String.replace(C.bad_source(), "integer()", "atom()", global: false)
      )

      {status, json, output} = C.lint(dir)
      assert status == 0, output
      assert [%{"mfa" => "Consumer.Bad.size/1"}] = json["baseline"]["stale_findings"]
      assert json["baseline"]["stale_inventory"] == []

      {_output, 0} = C.mix(dir, ["spec_lint.baseline"])
      refute Enum.any?(C.read_baseline!(dir)["findings"], &(&1["mfa"] == "Consumer.Bad.size/1"))
      {0, json, _output} = C.lint(dir)
      assert json["baseline"]["stale_findings"] == []

      # Removing a spec from a function that stays exported is a coverage
      # regression until the baseline is regenerated.
      Fixture.write!(dir, "lib/consumer.ex", """
      defmodule Consumer do
        def greet(name) when is_atom(name), do: "hello " <> Atom.to_string(name)
      end
      """)

      {status, json, output} = C.lint(dir)
      assert status == 1, output

      assert [
               %{
                 "rule" => "SL008",
                 "subject" => "Consumer.greet/1",
                 "data" => %{"reason" => "spec_removed"}
               }
             ] =
               blocking(json)

      assert json["ledger"]["lost_analysis"] == %{"spec_removed" => 1}
      {_output, 0} = C.mix(dir, ["spec_lint.baseline"])
      {0, _json, output} = C.lint(dir)
      refute output =~ "Traceback"

      # Deleting a module is not a regression, but its entries are stale
      # inventory until the baseline is regenerated.
      File.rm!(Path.join(dir, "lib/worse.ex"))
      {status, json, output} = C.lint(dir)
      assert status == 0, output
      assert [%{"mfa" => "Consumer.Worse.label/1"} | _] = json["baseline"]["stale_findings"]
      {_output, 0} = C.mix(dir, ["spec_lint.baseline"])
      {0, json, _output} = C.lint(dir)
      assert json["baseline"]["stale_findings"] == []
      assert json["baseline"]["stale_inventory"] == []
    end
  end

  describe "git dependency" do
    @tag timeout: 900_000
    test "(a, b) fetch from a repository, first run, baseline and a clean --ci run" do
      repo = C.snapshot_repo!(rm_on_exit(Fixture.tmp_dir!("snapshot")))
      dir = consumer("install-git", C.git_dep(repo))
      Fixture.write!(dir, "lib/bad.ex", C.bad_source())

      # The dependency is fetched from the repository; its own development
      # dependencies (Credo, Dialyxir) are not needed.
      {output, 0} = C.mix(dir, ["deps.get"])
      assert output =~ "spec_lint"
      lock = File.read!(Path.join(dir, "mix.lock"))
      assert lock =~ ~s("spec_lint": {:git, "#{repo}")

      refute File.exists?(Path.join(dir, "deps/credo")),
             "a consumer does not fetch spec_lint's development dependencies"

      {status, json, output} = C.lint(dir)
      assert status == 1, output
      assert json["adapter"] == C.adapter_id()
      assert json["baseline"]["applied"] == false
      assert json["baseline"]["new"] == 3

      {output, 0} = C.mix(dir, ["spec_lint.baseline"])
      assert output =~ "3 finding(s)"
      {status, json, output} = C.lint(dir)
      assert status == 0, output
      assert json["baseline"]["baselined"] == 3

      # The git dependency and the path dependency agree: the same
      # fingerprints for the same sources.
      path_dir = consumer("install-git-vs-path", C.path_dep())
      Fixture.write!(path_dir, "lib/bad.ex", C.bad_source())
      {_output, 0} = C.mix(path_dir, ["spec_lint.baseline"])
      assert fingerprints(C.read_baseline!(path_dir)) == fingerprints(C.read_baseline!(dir))
    end
  end

  describe "umbrella consumer" do
    @root_mix """
    defmodule Umbrella.MixProject do
      use Mix.Project

      def project do
        [
          apps_path: "apps",
          version: "0.1.0",
          deps: [__DEP__]
        ]
      end
    end
    """

    @child_mix """
    defmodule __MODULE__.MixProject do
      use Mix.Project

      def project do
        [
          app: :__APP__,
          version: "0.1.0",
          build_path: "../../_build",
          config_path: "../../config/config.exs",
          deps_path: "../../deps",
          lockfile: "../../mix.lock",
          deps: __DEPS__
        ]
      end
    end
    """

    defp umbrella! do
      dir = Fixture.tmp_dir!("install-umbrella")
      on_exit(fn -> File.rm_rf!(dir) end)

      Fixture.write!(dir, "mix.exs", String.replace(@root_mix, "__DEP__", C.path_dep()))
      Fixture.write!(dir, "config/config.exs", "import Config\n")
      Fixture.write!(dir, "apps/app_a/mix.exs", child("AppA", :app_a, "[]"))

      Fixture.write!(
        dir,
        "apps/app_b/mix.exs",
        child("AppB", :app_b, "[{:app_a, in_umbrella: true}]")
      )

      Fixture.write!(dir, "apps/app_a/lib/app_a.ex", """
      defmodule AppA do
        @spec greet(atom()) :: String.t()
        def greet(name) when is_atom(name), do: "hello " <> Atom.to_string(name)
      end
      """)

      Fixture.write!(dir, "apps/app_b/lib/app_b.ex", """
      defmodule AppB do
        @spec shout(atom()) :: String.t()
        def shout(name) when is_atom(name), do: String.upcase(AppA.greet(name))
      end
      """)

      dir
    end

    defp child(module, app, deps) do
      @child_mix
      |> String.replace("__MODULE__", module)
      |> String.replace("__APP__", Atom.to_string(app))
      |> String.replace("__DEPS__", deps)
    end

    test "(e) install at the root, first run, baseline and a clean --ci run" do
      dir = umbrella!()

      {status, json, output} = C.lint(dir)
      assert status == 0, output
      assert json["project"]["umbrella"] == true
      assert json["ledger"]["modules"]["discovered"] == 2
      assert json["ledger"]["slices"]["compared"] == 2
      assert json["baseline"]["applied"] == false
      refute File.exists?(C.baseline_path(dir))

      # A finding in one child, with a path relative to the umbrella root.
      Fixture.write!(dir, "apps/app_b/lib/app_b/bad.ex", """
      defmodule AppB.Bad do
        @spec size(atom()) :: integer()
        def size(name) when is_atom(name), do: name
      end
      """)

      {status, json, output} = C.lint(dir)
      assert status == 1, output

      assert [%{"subject" => "AppB.Bad.size/1", "file" => "apps/app_b/lib/app_b/bad.ex"}] =
               json["findings"]

      # One baseline at the umbrella root covers both children.
      {output, 0} = C.mix(dir, ["spec_lint.baseline"])
      assert output =~ "1 finding(s), 3 inventory entries"
      assert File.exists?(C.baseline_path(dir))
      refute File.exists?(Path.join(dir, "apps/app_b/.spec_lint_baseline.json"))

      {status, json, output} = C.lint(dir)
      assert status == 0, output
      assert json["baseline"]["baselined"] == 1

      # `--app` narrows the run to one child and makes it partial; the
      # baseline task refuses it, because it would drop the other child's
      # entries.
      {status, json, output} = C.lint(dir, ["--app", "app_a"])
      assert status == 0, output
      assert json["completion"]["status"] == "partial"
      assert json["ledger"]["modules"]["analysed"] == 1

      {output, 2} = C.mix(dir, ["spec_lint.baseline", "--app", "app_a"])
      assert output =~ "analyses the whole project"

      # The task belongs to the umbrella root, where the dependency is
      # declared; a child without the dependency does not have it.
      {output, status} = C.mix(Path.join(dir, "apps/app_b"), ["spec_lint", "--ci"])
      assert status != 0
      assert output =~ "The task \"spec_lint\" could not be found"
    end
  end

  ## Helpers

  defp blocking(json), do: Enum.filter(json["findings"], & &1["blocking"])

  defp fingerprints(baseline),
    do: baseline["findings"] |> Enum.map(&{&1["mfa"], &1["fingerprint"]}) |> Enum.sort()

  defp entry!(dir, mfa) do
    dir |> C.read_baseline!() |> Map.fetch!("findings") |> Enum.find(&(&1["mfa"] == mfa)) ||
      flunk("no baseline entry for #{mfa}")
  end

  defp annotate!(dir, mfa, fields) do
    baseline = C.read_baseline!(dir)

    findings =
      for entry <- baseline["findings"],
          do: if(entry["mfa"] == mfa, do: Map.merge(entry, fields), else: entry)

    C.write_baseline!(dir, %{baseline | "findings" => findings})
  end
end
