#!/usr/bin/env bash
# Runs on a fresh checkout after install_ci_elixir.sh. Linux GNU time and
# timeout required. A digest mismatch fails; this script never repins it.
set -euo pipefail
[ "$#" -eq 2 ] || { echo "usage: $0 gating|report-only ARTIFACT_DIR" >&2; exit 2; }
mode="$1" artifacts="$2"
case "$mode" in gating|report-only) ;; *) exit 2 ;; esac
mkdir -p "$artifacts"
# One VM per command; resource measurements remain available on failure.
export ERL_FLAGS="${ERL_FLAGS:-+S 4:4}"
export MIX_ENV=test
export MIX_BUILD_PATH="${MIX_BUILD_PATH:-$PWD/_build/linux-qualification}"
seconds="${SPEC_LINT_CI_TIMEOUT_S:-1200}"
rss_kb="${SPEC_LINT_CI_MAX_RSS_KB:-6291456}"
run() {
  local label="$1" status=0 peak
  shift
  /usr/bin/time -v -o "$artifacts/$label.resources.txt" \
    timeout --kill-after=15s "${seconds}s" "$@" >"$artifacts/$label.log" 2>&1 || status=$?
  cat "$artifacts/$label.log"
  peak="$(awk -F': ' '/Maximum resident set size/ {print $2}' "$artifacts/$label.resources.txt")"
  if [ -z "$peak" ] || [ "$peak" -gt "$rss_kb" ]; then
    echo "$label: missing measurement or RSS budget exceeded ($peak / $rss_kb KiB)" >&2
    return 2
  fi
  [ "$status" -eq 0 ] || { echo "$label failed (exit $status)" >&2; return "$status"; }
}
run dependencies mix deps.get
run compile mix compile --warnings-as-errors
run format mix format --check-formatted
run credo mix credo --strict
run preflight mix run -e 'case SpecLint.Compiler.preflight() do {:ok, caps} -> IO.inspect(caps, limit: :infinity); other -> IO.inspect(other, limit: :infinity); System.halt(2) end'
run gating_policy mix run -e 'mode = hd(System.argv()); {:ok, caps} = SpecLint.Compiler.preflight(); reasons = SpecLint.Compiler.Gating.reasons(caps); IO.inspect(reasons); expected = if mode == "gating", do: reasons == [], else: reasons != []; unless expected, do: System.halt(2)' -- "$mode"
if [ "$mode" = gating ]; then
  : "${SPEC_LINT_OTHER_ELIXIR:?provide another qualified gating compiler bin directory}"
  run alternate_preflight env PATH="$SPEC_LINT_OTHER_ELIXIR:$PATH" MIX_BUILD_PATH="$PWD/_build/linux-alternate" \
    mix run -e 'case SpecLint.Compiler.preflight() do {:ok, caps} -> IO.inspect(caps, limit: :infinity); unless SpecLint.Compiler.Gating.reasons(caps) == [], do: System.halt(2); other -> IO.inspect(other, limit: :infinity); System.halt(2) end'
  run tests mix test
  # Explicit --only prevents an accidentally excluded cross-compiler suite
  # from appearing as successful qualification.
  run cross_compiler mix test --only cross_compiler
  compiler_revision="$(elixir -e 'IO.write(System.build_info()[:revision])')"
  if [[ "$compiler_revision" == c24c235* ]]; then
    : "${SPEC_LINT_DIAGNOSTIC_ELIXIR:?provide the qualified 648b2a9 bin directory}"
    run diagnostic_dependency mix test --only diagnostic_dependency
  fi
  # Fixtures intentionally carry invalid specs; analyze production modules
  # in a separate dev build so test/support is never part of the target.
  run dialyzer env MIX_ENV=dev MIX_BUILD_PATH="${MIX_BUILD_PATH}-dialyzer" mix dialyzer
else
  # The upstream compiler is a diagnostic lane, not CI gating qualification.
  run upstream_diagnostics mix test test/spec_lint/compiler_gating_test.exs test/spec_lint/upstream_qualification_test.exs test/integration/report_only_compiler_test.exs
fi
