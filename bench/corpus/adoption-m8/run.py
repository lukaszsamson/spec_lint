"""Run prepared isolated projects using explicitly selected compiler PATH.
ADOPTION_ROOT: projects/ and evidence/. SPEC_LINT_ROOT: tool checkout.
This corrected runner was written after the measured campaign; results.json
records the actual campaign and explicitly retains the failed Nerves retries.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time

base = Path(os.environ.get("ADOPTION_ROOT", "/private/tmp/spec-lint-adoption-m8")).resolve()
root = Path(os.environ.get("SPEC_LINT_ROOT", Path(__file__).resolve().parents[3])).resolve()
env = dict(os.environ, MIX_ENV="test")
evidence = base / "evidence"
evidence.mkdir(parents=True, exist_ok=True)
input_path = evidence / "inputs.json"
if not input_path.exists():
    input_path = Path(__file__).resolve().with_name("inputs.json")
inputs = json.loads(input_path.read_text())
files = [root / "mix.exs", *sorted((root / "lib").rglob("*.ex"))]
(evidence / "runtime-snapshot.json").write_text(json.dumps({
    "git_head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
    "files": {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files},
}, indent=2) + "\n")


def measure(directory, output, label, arguments):
    log = output / (label + ".log")
    resources = output / (label + ".resources.txt")
    started = time.monotonic()
    intervention = None
    with log.open("w") as stream:
        process = subprocess.Popen(["/usr/bin/time", "-l", "-o", str(resources),
                                    "mix", *arguments], cwd=directory, env=env,
                                   stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
        while process.poll() is None:
            elapsed = time.monotonic() - started
            rows = subprocess.check_output(["ps", "-Ao", "pid,ppid,rss"], text=True).splitlines()[1:]
            descendants = {process.pid}
            parsed = [tuple(map(int, row.split())) for row in rows if len(row.split()) == 3]
            for _ in range(4):
                descendants.update(pid for pid, parent, rss in parsed if parent in descendants)
            peak_sample = max((rss for pid, parent, rss in parsed if pid in descendants), default=0)
            if elapsed >= 600 or peak_sample > 8 * 1024 * 1024:
                intervention = "wall_safety" if elapsed >= 600 else "rss_safety"
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                break
            time.sleep(1)
        code = process.wait()
    seconds = round(time.monotonic() - started, 2)
    text = resources.read_text() if resources.exists() else ""
    match = re.search(r"(\d+)\s+maximum resident set size", text)
    rss = int(match.group(1)) if match else None
    return {"exit": code, "seconds": seconds, "peak_rss_bytes": rss,
            "intervention": intervention,
            "measurement_complete": rss is not None,
            "safety_ceiling_exceeded": seconds > 600 or bool(rss and rss > 8 * 1024**3)}


def complete_report(path, process_result):
    if (process_result["exit"] not in (0, 1)
            or not process_result["measurement_complete"]
            or process_result["intervention"]
            or process_result["safety_ceiling_exceeded"]):
        return False
    try:
        completion = json.loads(path.read_text())["completion"]
        return completion["status"] == "complete" and completion["exit_code"] == process_result["exit"]
    except (OSError, ValueError, KeyError):
        return False


results = []
for item in inputs:
    name = item["project"]
    directory = base / "projects" / name
    output = evidence / name
    output.mkdir(parents=True, exist_ok=True)
    baseline = directory / ".spec_lint_baseline.json"
    if baseline.exists():
        raise RuntimeError(f"fresh campaign requires no existing baseline: {baseline}")
    row = {"project": name, "env": "test", "runs": {}}
    for label in ("cold", "incremental", "baseline", "baseline-ci"):
        report = output / (label + ".json")
        report.unlink(missing_ok=True)
        args = ["spec_lint.baseline", "--output", str(baseline)] if label == "baseline" else [
            "spec_lint", "--ci", "--format", "json", "--output", str(report)]
        measured = measure(directory, output, label, args)
        row["runs"][label] = measured
        print(name, label, measured, flush=True)
        if label == "baseline":
            if (measured["exit"] != 0 or not baseline.exists()
                    or not measured["measurement_complete"] or measured["intervention"]
                    or measured["safety_ceiling_exceeded"]):
                break
        elif not complete_report(report, measured):
            break
    row["lock_unchanged"] = hashlib.sha256((directory / "mix.lock").read_bytes()).hexdigest() == item["lock_sha256"]
    results.append(row)
    (evidence / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    if not row["lock_unchanged"]:
        raise RuntimeError(f"lock changed during campaign: {name}")
