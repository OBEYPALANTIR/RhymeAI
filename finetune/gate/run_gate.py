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

from gate.build import DEV_VERSION, FROZEN_VERSION, REPO, SEEDS, audit_overlap, freeze, prepare_dev, read_jsonl, require_mode, write_json
from gate.generate import freeze_prompts, generate, select_incumbent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", required=True, type=Path)
    parser.add_argument("--dev-songs", type=Path, help="Separate DEV corpus JSONL; informational results, never an adoption verdict")
    parser.add_argument("--dev-expanded-words", action="store_true",
                        help="DEV only: up to five distinct word selections per song, all three actions, and six synonym requests (first 20 songs)")
    parser.add_argument("--incumbent", type=Path, help="Shipped GGUF override; must match the candidate's structural size")
    parser.add_argument("--candidate-seed-offset", type=int, default=0,
                        help="Null noise control: shift candidate seeds; default keeps paired same-seed comparison")
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    if args.dev_expanded_words and not args.dev_songs:
        parser.error("--dev-expanded-words requires --dev-songs")
    offset = args.candidate_seed_offset
    if offset < 0 or max(SEEDS) + offset + 10000 > 2**31 - 1:
        parser.error("candidate seed offset must preserve nonnegative signed 32-bit sampler seeds")
    incumbent_seeds = {s + retry for s in SEEDS for retry in (0, 10000)}
    if offset and not incumbent_seeds.isdisjoint({s + offset for s in incumbent_seeds}):
        parser.error("nonzero candidate seed offset must give disjoint initial and retry seeds")
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    with (out / "run.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        require_mode(out, DEV_VERSION if args.dev_songs else FROZEN_VERSION)
        for name in ("summary.json", "report.md"):
            (out / name).unlink(missing_ok=True)
        phase = "freeze"
        try:
            write_json(out / "status.json", {"phase": phase, "complete": False})
            if args.dev_songs:
                prepare_dev(out, args.dev_songs, expanded_words=args.dev_expanded_words)
            else:
                freeze(out)
            phase = "model-size"
            incumbent = select_incumbent(args.candidate, args.incumbent)
            phase = "prompt-parity"
            freeze_prompts(out)
            for role, path in (("candidate", args.candidate), ("incumbent", incumbent)):
                phase = f"generate-{role}"
                print(phase, flush=True)
                write_json(out / "status.json", {"phase": phase, "complete": False})
                generate(out, role, path, offset if role == "candidate" else 0)
            phase = "judge"
            write_json(out / "status.json", {"phase": phase, "complete": False})
            from gate.judge import judge
            judge(out)
            phase = "report"
            overlap = audit_overlap(read_jsonl(out / "benchmark-songs.jsonl"), include_frozen=bool(args.dev_songs))
            write_json(out / "overlap-final.json", overlap)
            if args.dev_songs and overlap["overlapping_lines"]:
                raise ValueError("DEV corpus overlaps the frozen benchmark or training pools")
            write_json(out / "provenance.json", {
                "source_head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, text=True).strip(),
                "command": sys.argv, "python": sys.version,
                "candidate_seed_offset": offset,
                "sampler_seeds": {"candidate": [s + offset for s in SEEDS], "incumbent": list(SEEDS)},
                "manual_gates": {"G7": "NOT RUN: physical Pixel", "G8": "NOT RUN: Tyler blind read"}})
            from gate.report import report
            verdict = report(out)
            write_json(out / "status.json", {"phase": "complete", "complete": True, "verdict": verdict})
            print(f"{verdict}: {out / 'report.md'}", flush=True)
        except Exception as error:
            (out / "summary.json").unlink(missing_ok=True)
            write_json(out / "status.json", {"phase": phase, "complete": False, "error": str(error)})
            (out / "report.md").write_text(f"# Gate incomplete\n\nRunner failed during {phase}: {error}\n\n"
                                           + "\n".join(f"- G{i}: FAIL (incomplete evidence)" for i in range(1, 7))
                                           + "\n- G7/G8: NOT RUN (manual).\n")
            raise


if __name__ == "__main__":
    main()
