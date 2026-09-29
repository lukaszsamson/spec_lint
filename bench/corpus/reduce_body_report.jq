# Keep detail for findings and changed modes, plus one auditable row for
# every function. The fields separate actual gates from report-only candidates.
.functions as $all
| .functions = [$all[] | select(
    .omission != null
    or ([.class[]] | unique | length) > 1
    or ([.warn[]] | any)
    or ([.gate[]] | any)
    or ([.candidate[]] | any)
    or ([.reported[]] | any)
    or ([.slices[].extra_warnings[]] | length) > 0
  )]
| .function_rows = [$all[] | {mfa, class, gate, candidate, reported, warn, sampled, omission}]
