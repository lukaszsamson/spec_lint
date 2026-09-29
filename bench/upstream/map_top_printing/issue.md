> DRAFT, NOT FILED. Reproduces on upstream 648b2a9. Read ../CHECKLIST.md
> before filing. Presentation only; consider bundling with the fun printing
> draft as one "type printer fidelity" issue if the maintainers prefer.

# A closed map equal to map() prints as an 11-domain literal

## Summary

A closed map type with a `term()` value for every key domain is `equal?` to
`open_map()`, but prints as a long literal instead of `map()`.

## Reproduction

```elixir
import Module.Types.Descr

kinds = [:atom, :integer, :float, :binary, :bitstring_no_binary, :pid, :port,
         :reference, :tuple, :map, :list, :fun]

m = closed_map(for k <- kinds, do: {[k], term()})

equal?(m, open_map())      #=> true
to_quoted_string(open_map()) #=> "map()"
to_quoted_string(m)
#=> %{atom() => term(), bitstring() => term(), float() => term(), fun() => term(),
#     integer() => term(), list() => term(), map() => term(), pid() => term(),
#     port() => term(), reference() => term(), tuple() => term()}
```

## Expected

`"map()"`.

## Actual (Elixir 1.21.0-dev, 648b2a9, OTP 28)

The long literal above. Types of this shape are what a spec like
`%{optional(any()) => any()}` translates to.

## Notes

Presentation only; no unsound result observed. Normalising domain-complete
maps to `map()` before printing would fix it.
