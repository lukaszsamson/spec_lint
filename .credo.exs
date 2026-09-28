%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/", "test/"], excluded: ["deps/", "_build/", "priv/"]},
      strict: true,
      checks: %{
        enabled: [
          {Credo.Check.Readability.MaxLineLength, [max_length: 98]},
          {Credo.Check.Readability.Specs, []}
        ]
      }
    }
  ]
}
