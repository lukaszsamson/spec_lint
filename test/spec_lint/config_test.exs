defmodule SpecLint.ConfigTest do
  use ExUnit.Case, async: true

  alias SpecLint.{CLI, Config, Rules}

  @moduletag :tmp_dir

  test "defaults: review profile, require_static_return false, SL004/5/7 off" do
    assert {:ok, config} = Config.load(System.tmp_dir!())
    assert config.profile == :review
    refute config.require_static_return
    assert {:ok, rules} = Config.enabled_rules(config, nil, [])
    ids = for {rule, _severity} <- rules, do: rule.id()
    assert ids == ~w(SL001 SL002 SL003 SL006 SL008)
  end

  test "loads .spec_lint.exs and rejects unknown keys", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, ".spec_lint.exs"), """
    [
      profile: :soundness,
      rules: [possible_missing_return: :info, SL004: :hint],
      coverage: [fail_on_regression: false, floor: 3],
      exclude: ["lib/generated/**"],
      require_static_return: true
    ]
    """)

    assert {:ok, config} = Config.load(tmp_dir)
    assert config.profile == :soundness
    assert config.rules == %{"SL002" => :info, "SL004" => :hint}
    assert config.coverage == %{fail_on_regression: false, floor: 3}
    assert config.require_static_return
    assert {:ok, rules} = Config.enabled_rules(config, nil, [])
    assert {Rules.PossibleMissingReturn, :info} in rules
    assert {Rules.PossibleMissingInput, :hint} in rules

    for {bad, message} <- [
          {"[colour: :red]", "unknown configuration key :colour"},
          {"[profile: :strict]", "invalid value for :profile"},
          {"[rules: [nope: :warning]]", "unknown rule :nope"},
          {"[rules: [SL001: :loud]]", "invalid severity :loud"},
          {"[coverage: [floor: -1]]", "invalid coverage setting :floor"},
          {"%{}", "must be a keyword list"},
          {"raise \"boom\"", "cannot evaluate"},
          {"throw(:x)", "cannot evaluate"},
          {"exit(:shutdown)", "cannot evaluate"}
        ] do
      File.write!(Path.join(tmp_dir, "bad.exs"), bad)
      assert {:error, error} = Config.load(tmp_dir, "bad.exs")
      assert error =~ message
    end

    assert {:error, error} = Config.load(tmp_dir, "missing.exs")
    assert error =~ "not found"
  end

  test "CLI overrides the file and rule selection" do
    {:ok, config} = Config.from_keyword(profile: :soundness)
    {:ok, cli} = CLI.parse(~w(--ci --profile review --warnings-as-errors --baseline b.json))
    assert {:ok, merged} = Config.merge_cli(config, CLI.config_overrides(cli))
    assert merged.profile == :review
    assert merged.warnings_as_errors
    assert merged.baseline == "b.json"

    assert {:ok, [{Rules.ReturnConflict, :warning}]} =
             Config.enabled_rules(merged, ["return_conflict"], [])

    assert {:ok, rules} = Config.enabled_rules(merged, nil, ["SL002", "SL008"])
    refute Enum.any?(rules, fn {rule, _} -> rule.id() in ["SL002", "SL008"] end)
    assert {:error, message} = Config.enabled_rules(merged, ["SL042"], [])
    assert message =~ "unknown rule"
  end

  test "config digest is stable and sensitive" do
    {:ok, a} = Config.from_keyword(profile: :review)
    {:ok, b} = Config.from_keyword(profile: :review)
    {:ok, c} = Config.from_keyword(profile: :soundness)
    assert Config.digest(a) == Config.digest(%{b | source: "elsewhere"})
    refute Config.digest(a) == Config.digest(c)
  end

  test "CLI parsing" do
    assert {:ok, cli} =
             CLI.parse(
               ~w(--format json --output o.json --module MyApp.A --module :ets --app a) ++
                 ~w(--rules SL001,SL002 --except sl008 --explain MyApp.A.f/2)
             )

    assert cli.format == :json
    assert cli.modules == [MyApp.A, :ets]
    assert cli.apps == [:a]
    assert cli.only == ["SL001", "SL002"]
    assert cli.except == ["sl008"]
    assert cli.explain == {MyApp.A, :f, 2}
    refute cli.ci

    assert {:error, "invalid options: --bogus"} = CLI.parse(["--bogus"])
    assert {:error, message} = CLI.parse(~w(--profile strict))
    assert message =~ "--profile must be"
    assert {:error, message} = CLI.parse(~w(--format sarif))
    assert message =~ "--format must be"
    assert {:error, message} = CLI.parse(~w(extra))
    assert message =~ "unexpected arguments"

    # --analysis goes through the configuration, where bodies is a
    # capability error of the run (exit 2), not a parse error.
    assert {:ok, %{analysis: :bodies} = cli} = CLI.parse(~w(--analysis bodies --module Foo))

    assert {:ok, %Config{analysis: :bodies}} =
             Config.merge_cli(%Config{}, CLI.config_overrides(cli))

    assert {:ok, %{analysis: :signatures}} = CLI.parse(~w(--analysis signatures))
    assert {:error, message} = CLI.parse(~w(--analysis everything))
    assert message =~ "--analysis must be signatures or bodies"
  end

  test "exclude globs" do
    alias SpecLint.Project
    assert Project.excluded?("lib/generated/a.ex", ["lib/generated/**"])
    assert Project.excluded?("lib/generated/deep/a.ex", ["lib/generated/**"])
    assert Project.excluded?("lib/x/proto.ex", ["lib/**/proto.ex"])
    assert Project.excluded?("lib/proto.ex", ["lib/**/proto.ex"])
    refute Project.excluded?("lib/a.ex", ["lib/*/a.ex"])
    refute Project.excluded?("lib/generatedx.ex", ["lib/generated/**"])
    refute Project.excluded?(nil, ["**"])
  end
end
