> DRAFT, NOT FILED. Reproduces on upstream 648b2a9. Read ../CHECKLIST.md
> before filing. Frame as a small performance note; upstream may reasonably
> say printing is not a hot path for the compiler.

# Descr.to_quoted_string/2 attempts a module load for every struct-shaped map it prints

## Summary

Printing a closed map type whose `:__struct__` is a single atom calls
`maybe_struct/1` (`struct.__info__(:struct)` inside `try/rescue`) each time.
For a struct module that cannot be loaded, every print goes through
`:error_handler.undefined_function/3` and the code server, and the cost per
print grows with the length of the code path. Printing also has a
side effect: it loads modules.

## Reproduction

```elixir
import Module.Types.Descr

absent =
  closed_map([
    {:__struct__, {atom([This.Struct.Module.Does.Not.Exist]), false}},
    {:a, {integer(), false}}
  ])

:erlang.trace_pattern({:error_handler, :undefined_function, 3}, true, [:call_count])
for _ <- 1..2000, do: to_quoted_string(absent)
:erlang.trace_info({:error_handler, :undefined_function, 3}, :call_count)
#=> {:call_count, 2000}
```

The attached `repro.exs` also times plain maps, loaded struct modules and
absent ones with 43, 143 and 443 entries on the code path.

## Expected

Printing does not load modules, or does not repeat a failed load for the
same module on every print.

## Actual (Elixir 1.21.0-dev, 648b2a9, OTP 28)

2000 prints of an absent struct: 2000 failed loads; about 24 us per print
with 43 code path entries against 6 us for a plain map, and about 1500 us
with 443 entries (empty synthetic directories).

## Context

Found while profiling a tool that prints many Blueprint-style struct types
(Absinthe): `maybe_struct/1`'s load was the largest bucket in the sampled
stacks, and in a later run each such load took seconds in a process holding
a multi-gigabyte heap. I have not separated absent modules from first-time
loads of present ones in that profile; the reproducer above isolates the
absent-module case. Options for the printer: skip the lookup when the module is not
already loaded (`:erlang.module_loaded/1`), make it opt-in through an option
of `to_quoted_string/2`, or cache negative lookups by the caller.
