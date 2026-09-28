defmodule SpecLint.Integration.CiQualificationTest do
  # CI qualification (DESIGN.md sections 8, 9 and 10) on a real umbrella
  # consumer, in a separate OS process like the other integration tests.
  #
  #   * an umbrella with two children (app_b depends on app_a): both are
  #     analysed once, their modules aggregated, and an SL001 injected in
  #     app_b is found; `--app` marks the run partial;
  #   * missing artifacts: a removed ebin exits 2 (`missing_build_path`),
  #     and a build without debug info is SL008 `missing_metadata`, never
  #     "no specs";
  #   * an adapter transition: a baseline written by another adapter is
  #     not applied, and `mix spec_lint.baseline` reconciles it.
  #
  # The fixture lives in the system temporary directory and is removed
  # after the tests. Every test starts from the pristine sources and a
  # fresh build of the children (`reset!/1`), so the order does not matter.
  use ExUnit.Case, async: false

  import SpecLint.ProjectFixture

  @moduletag :integration
  @moduletag timeout: 600_000

  # UMBRELLA_SKIP_COMPILE turns the root `compile` into a no-op, so a
  # removed build directory, or a build made with other options, is kept
  # when mix spec_lint runs.
  @skip_compile [{"UMBRELLA_SKIP_COMPILE", "1"}]

  @root_mix """
  defmodule Umbrella.MixProject do
    use Mix.Project

    def project do
      [
        apps_path: "apps",
        version: "0.1.0",
        aliases: aliases(),
        deps: [{:spec_lint, path: #{inspect(SpecLint.ProjectFixture.root())}, only: [:dev, :test], runtime: false}]
      ]
    end

    defp aliases do
      if System.get_env("UMBRELLA_SKIP_COMPILE"), do: [compile: fn _ -> :ok end], else: []
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

  @sources %{
    "apps/app_a/lib/app_a.ex" => """
    defmodule AppA do
      @spec greet(atom()) :: String.t()
      def greet(name) when is_atom(name), do: "hello " <> Atom.to_string(name)
    end
    """,
    "apps/app_a/lib/app_a/util.ex" => """
    defmodule AppA.Util do
      @spec double(integer()) :: integer()
      def double(n) when is_integer(n), do: n * 2
    end
    """,
    "apps/app_b/lib/app_b.ex" => """
    defmodule AppB do
      @spec shout(atom()) :: String.t()
      def shout(name) when is_atom(name), do: String.upcase(AppA.greet(name))
    end
    """
  }

  @bad_source """
  defmodule AppB.Bad do
    @spec size(atom()) :: integer()
    def size(name) when is_atom(name), do: name
  end
  """

  @bad_path "apps/app_b/lib/app_b/bad.ex"

  setup_all do
    dir = tmp_dir!("umbrella")
    on_exit(fn -> File.rm_rf!(dir) end)

    write!(dir, "mix.exs", @root_mix)
    write!(dir, "config/config.exs", "import Config\n")
    write!(dir, "apps/app_a/mix.exs", child_mix("AppA", :app_a, "[]"))

    write!(
      dir,
      "apps/app_b/mix.exs",
      child_mix("AppB", :app_b, "[{:app_a, in_umbrella: true}]")
    )

    %{dir: dir}
  end

  setup %{dir: dir} do
    reset!(dir)
    :ok
  end

  defp child_mix(module, app, deps) do
    @child_mix
    |> String.replace("__MODULE__", module)
    |> String.replace("__APP__", Atom.to_string(app))
    |> String.replace("__DEPS__", deps)
  end

  # Pristine sources, no baseline, and freshly built children.
  defp reset!(dir) do
    File.rm(Path.join(dir, @bad_path))
    File.rm(Path.join(dir, ".spec_lint_baseline.json"))
    File.rm(Path.join(dir, "report.json"))
    for app <- ~w(app_a app_b), do: File.rm_rf!(Path.join(dir, "_build/dev/lib/#{app}"))
    for {path, contents} <- @sources, do: write!(dir, path, contents)
    {output, status} = mix(dir, ["compile"])
    assert status == 0, output
  end

  defp beam_modules(json), do: for(beam <- json["beams"], do: beam["module"])

  test "umbrella: both children analysed once, an SL001 in app_b, --app is partial", %{dir: dir} do
    {status, json, output} = lint(dir)
    assert status == 0, output
    assert json["project"]["umbrella"] == true
    assert json["findings"] == []

    # Owned modules of both children, aggregated, each exactly once.
    assert beam_modules(json) == ["AppA", "AppA.Util", "AppB"]

    assert Enum.map(json["beams"], & &1["path"]) == [
             "_build/dev/lib/app_a/ebin/Elixir.AppA.beam",
             "_build/dev/lib/app_a/ebin/Elixir.AppA.Util.beam",
             "_build/dev/lib/app_b/ebin/Elixir.AppB.beam"
           ]

    assert json["ledger"]["functions"]["found"] == 3
    assert json["ledger"]["slices"]["compared"] == 3

    # The scope block lists both apps and is not partial.
    assert %{"partial" => false, "apps" => ["app_a", "app_b"], "app_filters" => []} =
             json["scope"]

    assert json["completion"]["status"] == "complete"

    # An injected SL001 in child B is found, with a path relative to the umbrella root.
    write!(dir, @bad_path, @bad_source)
    {status, json, output} = lint(dir)
    assert status == 1, output
    assert beam_modules(json) == ["AppA", "AppA.Util", "AppB", "AppB.Bad"]

    assert [
             %{
               "rule" => "SL001",
               "subject" => "AppB.Bad.size/1",
               "evidence" => "conflict",
               "gate" => true,
               "blocking" => true,
               "baseline" => "new",
               "file" => "apps/app_b/lib/app_b/bad.ex"
             }
           ] = json["findings"]

    assert json["ledger"]["functions"]["found"] == 4

    # --app filtering marks the run partial and analyses only that child.
    {status, json, output} = lint(dir, ["--app", "app_a"])
    assert status == 0, output
    assert beam_modules(json) == ["AppA", "AppA.Util"]
    assert json["findings"] == []
    assert json["completion"]["status"] == "partial"

    assert %{"partial" => true, "apps" => ["app_a"], "app_filters" => ["app_a"]} =
             json["scope"]

    {status, json, output} = lint(dir, ["--app", "app_b"])
    assert status == 1, output
    assert beam_modules(json) == ["AppB", "AppB.Bad"]
    assert [%{"subject" => "AppB.Bad.size/1"}] = json["findings"]
    assert json["completion"]["status"] == "partial"
    assert json["scope"]["apps"] == ["app_b"]

    # An app the umbrella does not own is a configuration error.
    {output, status} = mix(dir, ["spec_lint", "--app", "nope"])
    assert status == 2
    assert output =~ "--app nope matches no owned application (owned: app_a, app_b)"
  end

  test "a removed child ebin exits 2 with missing_build_path, never zero specs", %{dir: dir} do
    File.rm_rf!(Path.join(dir, "_build/dev/lib/app_b/ebin"))

    {status, json, output} = lint(dir, [], @skip_compile)
    assert status == 2, output
    assert output =~ "missing build directory for app_b (_build/dev/lib/app_b/ebin)"
    refute output =~ "0 specs checked"
    assert json == nil

    # The same without --ci: a configuration error is exit 2 as well.
    {output, status} = mix(dir, ["spec_lint"], @skip_compile)
    assert status == 2, output
    assert output =~ "missing build directory for app_b"
  end

  test "a build without debug info is SL008 missing_metadata, never no specs", %{dir: dir} do
    {output, status} = mix(dir, ["compile", "--force", "--no-debug-info"])
    assert status == 0, output

    {status, json, output} = lint(dir, [], @skip_compile)
    assert status == 1, output
    assert beam_modules(json) == ["AppA", "AppA.Util", "AppB"]

    findings = Enum.sort_by(json["findings"], & &1["subject"])
    assert Enum.map(findings, & &1["subject"]) == ["AppA", "AppA.Util", "AppB"]

    for finding <- findings do
      assert %{
               "rule" => "SL008",
               "evidence" => "unavailable",
               "blocking" => true,
               "baseline" => "new",
               "data" => %{"reason" => "missing_metadata", "status" => "unavailable"}
             } = finding
    end

    assert json["ledger"]["modules"]["unavailable"] == %{"missing_metadata" => 3}
    assert json["completion"]["status"] == "complete"
    assert json["completion"]["blocking"] == 3

    # Not a project with zero specs: it fails, and only because nothing
    # could be read. (The console and summary line still say "0 specs
    # checked"; that wording is reported, not asserted.)
    assert json["ledger"]["functions"]["found"] == 0
  end

  test "a baseline of another adapter is not applied; the baseline task reconciles it",
       %{dir: dir} do
    write!(dir, @bad_path, @bad_source)
    {output, 0} = mix(dir, ["spec_lint.baseline"])
    assert output =~ "1 finding(s)"

    baseline = baseline!(dir)
    adapter = baseline["adapter"]
    assert [%{"rule" => "SL001", "adapter" => ^adapter} = entry] = baseline["findings"]
    assert {status, json, _} = lint(dir)
    assert status == 0
    assert json["adapter"] == adapter

    # The same file, written by another adapter, with a reviewed reason and
    # an entry that no longer matches anything.
    stale = %{entry | "fingerprint" => "sha256:0000", "mfa" => "AppB.Gone.size/1"}

    old =
      Map.merge(baseline, %{
        "adapter" => "1.20.0+other",
        "findings" => [
          %{entry | "adapter" => "1.20.0+other", "reason" => "reviewed", "owner" => "me"},
          stale
        ]
      })

    File.write!(Path.join(dir, ".spec_lint_baseline.json"), JSON.encode!(old))

    # Not applied and not silently accepted: the finding is new and
    # blocking, the run says why, and CI exits 2.
    {status, json, output} = lint(dir)
    assert status == 2, output

    assert %{"applied" => false, "reason" => "adapter_mismatch", "baselined" => 0, "new" => 1} =
             json["baseline"]

    assert [%{"rule" => "SL001", "baseline" => "new", "blocking" => true}] = json["findings"]
    assert json["completion"]["exit_code"] == 2
    [reason] = json["completion"]["reasons"]
    assert reason =~ "was written by adapter 1.20.0+other, the current adapter is #{adapter}"
    assert reason =~ "regenerate it with mix spec_lint.baseline"

    # Not silently dropped either: no stale entries are declared, and the
    # file is untouched by the run.
    assert json["baseline"]["stale_findings"] == []
    assert baseline!(dir) == old

    # Outside CI the run reports the mismatch and does not fail on it.
    {output, 0} = mix(dir, ["spec_lint"])
    assert output =~ "NOT applied: written by adapter 1.20.0+other"

    # The baseline task rechecks every entry with the running adapter.
    {output, 0} = mix(dir, ["spec_lint.baseline"])
    assert output =~ "1 finding(s)"
    new = baseline!(dir)
    assert new["adapter"] == adapter
    assert [%{"fingerprint" => fingerprint} = rewritten] = new["findings"]
    assert fingerprint == entry["fingerprint"]
    assert rewritten["adapter"] == adapter
    assert rewritten["reason"] == "reviewed"
    assert rewritten["owner"] == "me"
    refute Map.has_key?(rewritten, "pending_reconciliation")
    refute Enum.any?(new["findings"], &(&1["fingerprint"] == "sha256:0000"))
    assert Enum.all?(new["findings"], &(&1["adapter"] == adapter))

    {status, json, output} = lint(dir)
    assert status == 0, output
    assert %{"applied" => true, "reason" => nil, "baselined" => 1} = json["baseline"]
    assert json["baseline"]["pending_reconciliation"] == []
    assert [%{"baseline" => "baselined", "blocking" => false}] = json["findings"]
  end

  test "an entry of another adapter in a current file acknowledges nothing", %{dir: dir} do
    write!(dir, @bad_path, @bad_source)
    {_output, 0} = mix(dir, ["spec_lint.baseline"])
    baseline = baseline!(dir)
    adapter = baseline["adapter"]
    [entry] = baseline["findings"]

    old = %{baseline | "findings" => [%{entry | "adapter" => "1.20.0+other"}]}
    File.write!(Path.join(dir, ".spec_lint_baseline.json"), JSON.encode!(old))

    # The file-level adapter matches, the entry's does not: the finding is
    # new (exit 1), and the entry is listed as pending, never stale.
    {status, json, output} = lint(dir)
    assert status == 1, output
    assert [%{"baseline" => "new", "blocking" => true}] = json["findings"]
    assert json["baseline"]["applied"] == true
    assert [%{"fingerprint" => fingerprint}] = json["baseline"]["pending_reconciliation"]
    assert fingerprint == entry["fingerprint"]
    assert json["baseline"]["stale_findings"] == []

    {_output, 0} = mix(dir, ["spec_lint.baseline"])
    assert [%{"adapter" => ^adapter} = rewritten] = baseline!(dir)["findings"]
    refute Map.has_key?(rewritten, "pending_reconciliation")
    assert {0, _json, _} = lint(dir)
  end
end
