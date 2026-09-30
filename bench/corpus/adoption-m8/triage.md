# Finding triage

## Absinthe: seven gates, one declared-type defect family

Pinned revision `66cec3445d1228a5b9b8df1184d30c6993ea1b79`.
All seven SL001 gates concern native-input clauses of
`Absinthe.Blueprint.Input.parse/1`, specified as `nil | t()`.
`Input.t()` includes Integer, Float, Null, String, Boolean, List and Object
struct types. Every corresponding declared struct type requires
`source_location: Blueprint.SourceLocation.t()`, a struct with positive
line and column. Native-input parsing constructs these structs with
`source_location: nil`. That returned field is outside the declaration.

An independent agent inspected the declarations and executed the compiled
public project under the exact qualified 1.20.4 compiler. Inputs `1`, `1.5`,
`nil`, `"text"`, `true`, `[1]` and `%{x: 1}` each returned the expected struct
with nil source location. The seven reported clauses map to these inputs.
This supports one shared library type defect; it does not establish seven
independent defects or improve the frozen recall score.

Collection declarations expose additional concrete discrepancies:
`Input.List.t().items` claims Value structs while native parsing produces
RawValue wrappers, and Object fields similarly contain RawValue where the
Field type claims Value. A fix needs to distinguish raw parser structures
from later processed structures, or permit their actual initial values.

Two advisory SL002 findings (Phase.Init.run/2 and
Subscription.PipelineSerializer.pack/1) are possible domain escapes.
They are not gates and are not counted as proven defects here.

## Tableau: one advisory, concrete omitted return alternative

Pinned revision `4922d7a2eb583203e2eb0b50a7b75fc02cfa7390`.
`Tableau.Extension.key/1` is declared to return `atom()`, but its source
returns `{:ok, module.__tableau_extension_key__()}` when the metadata function
exists, and `:error` otherwise. Executing the compiled public module with a
small witness module exporting `__tableau_extension_key__/0` returning
`:campaign` produced `{:ok, :campaign}`. This tuple is outside `atom()`.

The advisory therefore identifies a real missing tuple alternative. It stays
non-gating because the compiler treats the tuple payload as gradual; the
concrete witness validates this particular advisory without changing the
rule's evidence requirements. The second return branch `:error` satisfies
the original declaration. A useful corrected declaration would describe
`{:ok, ...} | :error` with the key's intended domain.

## Retained executable witnesses

From the corresponding pinned, compiled project copy, run
`MIX_ENV=test mix run --no-start /path/to/witnesses.exs absinthe` or
`... tableau`. Both passed on the campaign's exact 1.20.4 compiler.
The Tableau witness also checks the compiled declaration and its atom-only
return; the Absinthe witness checks the returned field values against the
declarations audited above. The script does not start either application.
