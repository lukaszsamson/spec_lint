# Research-only analysis/evidence retention experiment. This is not a Run
# replacement: it does not execute rules, reachability, baselines or policy.
# Usage: mix run bench/memory/retention.exs retain|discard BUILD_LIB_DIR APP
# The caller must establish compiler provenance for these explicit inputs.
[mode, build_lib, app] = System.argv()
unless mode in ["retain", "discard"], do: raise("expected retain or discard")
for ebin <- Path.wildcard(Path.join(build_lib, "*/ebin")), do: Code.prepend_path(ebin)
{:ok, caps} = SpecLint.Compiler.preflight()
paths = Path.wildcard(Path.join([build_lib, app, "ebin", "*.beam"])) |> Enum.sort()
if paths == [], do: raise("no BEAM inputs")
cache = SpecLint.TypeCache.new()
started = System.monotonic_time(:millisecond)

{inventory, retained} =
  try do
    Enum.reduce(paths, {[], []}, fn path, {entries, retained} ->
      result = SpecLint.Analysis.module(path, cache: cache, preflight: {:ok, caps})

      unless result.status in [:ok, {:out_of_scope, :erlang_module}],
        do: raise("unavailable module: #{inspect(result.status)}")

      evidence =
        for function <- result.functions,
            slice <- function.slices,
            slice.relations != nil,
            into: %{},
            do: {{function.mfa, slice.index}, SpecLint.Evidence.classify(slice.relations)}

      entries = SpecLint.Coverage.inventory([result], evidence) ++ entries
      retained = if mode == "retain", do: [{result, evidence} | retained], else: retained
      {entries, retained}
    end)
  after
    SpecLint.TypeCache.delete(cache)
  end

:erlang.garbage_collect()
# Observe the list after the memory sample to keep it live in retain mode.
{:memory, heap_bytes} = Process.info(self(), :memory)
retained_count = length(retained)
inventory = Enum.sort_by(inventory, &{&1.module, &1.mfa || "", &1.slice || -1})

digest =
  :crypto.hash(:sha256, :erlang.term_to_binary(inventory, [:deterministic]))
  |> Base.encode16(case: :lower)

IO.puts(
  JSON.encode!(%{
    mode: mode,
    adapter: caps.adapter_id,
    modules: length(paths),
    entries: length(inventory),
    inventory_sha256: digest,
    retained_modules: retained_count,
    process_memory_after_gc: heap_bytes,
    elapsed_ms: System.monotonic_time(:millisecond) - started
  })
)
