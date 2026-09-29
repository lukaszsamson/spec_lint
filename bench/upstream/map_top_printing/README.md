# map_top_printing

Upstream status (648b2a9): reproduces. Also on 1.20.4. Kind: printer
presentation only; no unsound result observed.

A closed map with one `term()`-valued domain per key kind and no required
keys is `equal?` to `open_map()` (`map()`), yet prints as an 11-line domain
literal.

Run: `elixir repro.exs`.

Source: `UPSTREAM_BUGS.txt` item 9. Such maps arise from every spec written
`%{optional(any()) => any()}` and from `Calendar.datetime()`-style types once
translated. SpecLint works around it in its own canonical printer.

## Expected vs actual

| Observation | Expected | Actual on 648b2a9 |
| --- | --- | --- |
| `equal?(m, open_map())` | `true` | `true` |
| `to_quoted_string(m)` | `map()` | `%{atom() => term(), bitstring() => term(), float() => term(), fun() => term(), integer() => term(), list() => term(), map() => term(), pid() => term(), port() => term(), reference() => term(), tuple() => term()}` |

(The `binary` domain is folded into `bitstring()` by the printer, so 12 key
kinds print as 11 domains.)

Suggested fix: normalise a closed map whose domains cover every key kind
with `term()` values and no required keys to `map()`, and more generally
collapse domain-complete maps before printing.
