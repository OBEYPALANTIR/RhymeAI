#!/usr/bin/env python3
"""One-command frozen Android gate; a failed gate is a result, not a runner error."""
from __future__ import annotations

import argparse
import fcntl
import json
import subprocess
import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from gate.build import REPO, audit_overlap, freeze, read_jsonl, write_json
from gate.generate import INCUMBENT, freeze_prompts, generate


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", required=True, type=Path)
    parser.add_argument("--incumbent", default=INCUMBENT, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    with (out / "run.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        phase = "freeze"
        try:
            write_json(out / "status.json", {"phase": phase, "complete": False})
            freeze(out)
            freeze_prompts(out)
            for role, path in (("candidate", args.candidate), ("incumbent", args.incumbent)):
                phase = f"generate-{role}"
                print(phase, flush=True)
                write_json(out / "status.json", {"phase": phase, "complete": False})
                generate(out, role, path)
            phase = "judge"
            write_json(out / "status.json", {"phase": phase, "complete": False})
            from gate.judge import judge
            judge(out)
            phase = "report"
            write_json(out / "overlap-final.json", audit_overlap(read_jsonl(out / "benchmark-songs.jsonl")))
            write_json(out / "provenance.json", {
                "source_head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, text=True).strip(),
                "command": sys.argv, "python": sys.version,
                "manual_gates": {"G7": "NOT RUN: physical Pixel", "G8": "NOT RUN: Tyler blind read"}})
            from gate.report import report
            verdict = report(out)
            write_json(out / "status.json", {"phase": "complete", "complete": True, "verdict": verdict})
            print(f"{verdict}: {out / 'report.md'}", flush=True)
        except Exception as error:
            write_json(out / "status.json", {"phase": phase, "complete": False, "error": str(error)})
            (out / "report.md").write_text(f"# Gate incomplete\n\nRunner failed during {phase}: {error}\n\n"
                                           + "\n".join(f"- G{i}: FAIL (incomplete evidence)" for i in range(1, 7))
                                           + "\n- G7/G8: NOT RUN (manual).\n")
            raise


if __name__ == "__main__":
    main()
