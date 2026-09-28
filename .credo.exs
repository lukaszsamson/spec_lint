%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/", "test/", "bench/"], excluded: ["deps/", "_build/", "priv/"]},
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
