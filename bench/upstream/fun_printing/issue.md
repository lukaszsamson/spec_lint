> DRAFT, NOT FILED. Reproduces on upstream 648b2a9. Read ../CHECKLIST.md
> before filing. Low priority; a question, not a demand.

# Type printer renders fun(n) and (none(), ... -> term()) identically although they are not equal

## Summary

`fun(2)` (all functions of arity 2) and `fun([none(), none()], term())` print
as the same string, but `equal?/2` says they differ, and `subtype?/2` holds
only from the arrow to `fun(2)`.

## Reproduction

```elixir
import Module.Types.Descr

a = fun(2)
b = fun([none(), none()], term())

to_quoted_string(a)  #=> "(none(), none() -> term())"
to_quoted_string(b)  #=> "(none(), none() -> term())"
equal?(a, b)         #=> false
subtype?(a, b)       #=> false
subtype?(b, a)       #=> true
```

## Expected

Either the two types are equal (an arrow with `none()` arguments accepts no
call, so every function of that arity is a subtype of it), or they print
differently, for example `fun(2)` for the top of the arity and the arrow only
for real argument types.

## Actual (Elixir 1.21.0-dev, 648b2a9, OTP 28)

As above. `fun(1)` and `fun(0)` print as `(none() -> term())` and
`(-> term())`.

## Question

Which side is intended: the printer (a display shorthand for the top of the
arity) or the algebra (the two are distinct)? If the printer is a shorthand,
readers of diagnostics cannot distinguish the two types.
