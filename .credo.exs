%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/", "test/"], excluded: ["deps/", "_build/", "test/tmp/"]},
      strict: true,
      checks: %{
        extra: [
          {Credo.Check.Readability.MaxLineLength, [max_length: 98]},
          {Credo.Check.Readability.Specs, []}
        ]
      }
    }
  ]
}
