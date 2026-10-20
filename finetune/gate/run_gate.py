#!/usr/bin/env python3
"""One-command frozen Android gate; a failed gate is a result, not a runner error."""
from __future__ import annotations

import argparse
import fcntl
import json
import subprocess
import sys
from contextlib import ExitStack
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from gate.build import DEV_VERSION, FROZEN_VERSION, V2_VERSION, REPO, SEEDS, audit_overlap, freeze, frozen_path, prepare_dev, read_jsonl, require_mode, write_json
from gate.generate import freeze_prompts, generate, select_incumbent
from gate.backend import tunnel_port
from gate.judge import credit_budget


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", required=True, type=Path)
    parser.add_argument("--benchmark", choices=("v1", "v2"), default="v1", help="Frozen benchmark version; v1 is retained for historical comparisons")
    parser.add_argument("--dev-songs", type=Path, help="Separate DEV corpus JSONL; informational results, never an adoption verdict")
    parser.add_argument("--dev-expanded-words", action="store_true",
                        help="DEV only: up to five distinct word selections per song, all three actions, and six synonym requests (first 20 songs)")
    parser.add_argument("--incumbent", type=Path, help="Shipped GGUF override; must match the candidate's structural size")
    parser.add_argument("--candidate-seed-offset", type=int, default=0,
                        help="Null noise control: shift candidate seeds; default keeps paired same-seed comparison")
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--server-url", help="Existing SSH tunnel, http://127.0.0.1:<port>; never starts a local server")
    parser.add_argument("--cloud-lane", type=Path, help="cloud_lane.py state; selects and SHA-verifies each arm on its VM")
    parser.add_argument("--dev-generation-only", action="store_true", help="DEV smoke: replay both arms offline, skip judging, no verdict")
    parser.add_argument("--judge-credit-budget", type=credit_budget, default=0,
                        help="Explicit ChatGPT credit budget across this run and resumes; 0 requires included allowance")
    args = parser.parse_args()
    if bool(args.server_url) != bool(args.cloud_lane):
        parser.error("--server-url and --cloud-lane are required together for verified remote inference")
    if args.server_url:
        tunnel_port(args.server_url)
    if args.dev_generation_only and not args.dev_songs:
        parser.error("--dev-generation-only requires --dev-songs; frozen gates always judge")
    if args.dev_expanded_words and not args.dev_songs:
        parser.error("--dev-expanded-words requires --dev-songs")
    if args.dev_songs and args.benchmark != "v1":
        parser.error("--benchmark v2 cannot be combined with --dev-songs")
    version = DEV_VERSION if args.dev_songs else {"v1": FROZEN_VERSION, "v2": V2_VERSION}[args.benchmark]
    if version == V2_VERSION and "margins" not in json.loads(frozen_path(version).read_text()):
        parser.error("V2 null calibration must freeze margins before any candidate evaluation")
    offset = args.candidate_seed_offset
    if offset < 0 or max(SEEDS) + offset + 10000 > 2**31 - 1:
        parser.error("candidate seed offset must preserve nonnegative signed 32-bit sampler seeds")
    incumbent_seeds = {s + retry for s in SEEDS for retry in (0, 10000)}
    if offset and not incumbent_seeds.isdisjoint({s + offset for s in incumbent_seeds}):
        parser.error("nonzero candidate seed offset must give disjoint initial and retry seeds")
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    with ExitStack() as stack, (out / "run.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if args.cloud_lane:
            from gate.cloud_lane import lane_lock, select_model
            stack.enter_context(lane_lock(args.cloud_lane))
        require_mode(out, version)
        for name in ("summary.json", "report.md"):
            (out / name).unlink(missing_ok=True)
        phase = "freeze"
        try:
            write_json(out / "status.json", {"phase": phase, "complete": False})
            if args.dev_songs:
                prepare_dev(out, args.dev_songs, expanded_words=args.dev_expanded_words)
            else:
                freeze(out, args.benchmark)
            phase = "model-size"
            incumbent = select_incumbent(args.candidate, args.incumbent)
            phase = "prompt-parity"
            freeze_prompts(out)
            for role, path in (("candidate", args.candidate), ("incumbent", incumbent)):
                phase = f"generate-{role}"
                print(phase, flush=True)
                write_json(out / "status.json", {"phase": phase, "complete": False})
                remote = {"server_url": args.server_url, "remote_proof": select_model(args.cloud_lane, path)} if args.server_url else {}
                generate(out, role, path, offset if role == "candidate" else 0, **remote)
            if args.dev_generation_only:
                from gate.generate import gradle
                proof = {"mode": DEV_VERSION, "judge": "NOT RUN", "verdict": "NOT RUN", "arms": {},
                         "source_head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, text=True).strip(),
                         "command": sys.argv}
                for role in ("candidate", "incumbent"):
                    phase = f"offline-replay-{role}"
                    gradle(out, "replay", role, seed_offset=offset if role == "candidate" else 0)
                    live = read_jsonl(out / f"replay-{role}.jsonl")
                    offline = read_jsonl(out / f"replayed-{role}.jsonl")
                    if live != offline or not all(r["offline_replay_equal"] for r in live):
                        raise ValueError("DEV smoke live/offline replay mismatch")
                    proof["arms"][role] = {"rows": len(live), "mismatches": 0,
                                           "backend": json.loads((out / f"binding-{role}.json").read_text())["backend"]}
                overlap = audit_overlap(read_jsonl(out / "benchmark-songs.jsonl"), include_frozen=True)
                write_json(out / "overlap-final.json", overlap)
                if overlap["overlapping_lines"]:
                    raise ValueError("DEV corpus overlaps the frozen benchmark or training pools")
                write_json(out / "generation-smoke.json", proof)
                write_json(out / "status.json", {"phase": "generation-only", "complete": False, "generation_complete": True,
                                                 "judge": "NOT RUN", "verdict": "NOT RUN"})
                (out / "report.md").write_text("# DEV generation smoke\n\nBoth arms match offline replay. Judge and adoption verdict: NOT RUN.\n")
                print(f"DEV generation smoke: {out / 'generation-smoke.json'}", flush=True)
                return
            phase = "judge"
            write_json(out / "status.json", {"phase": phase, "complete": False})
            from gate.judge import judge
            judge(out, judge_credit_budget=args.judge_credit_budget)
            judge_provenance = json.loads((out / "judge-provenance.json").read_text())
            phase = "report"
            overlap = audit_overlap(read_jsonl(out / "benchmark-songs.jsonl"), include_frozen=bool(args.dev_songs), benchmark=args.benchmark)
            write_json(out / "overlap-final.json", overlap)
            if args.dev_songs and overlap["overlapping_lines"]:
                raise ValueError("DEV corpus overlaps the frozen benchmark or training pools")
            write_json(out / "provenance.json", {
                "source_head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, text=True).strip(),
                "benchmark_version": version,
                "judge_rubric": {key: judge_provenance[key] for key in ("rubric_version", "rubric_sha256")},
                "command": sys.argv, "python": sys.version,
                "candidate_seed_offset": offset,
                "sampler_seeds": {"candidate": [s + offset for s in SEEDS], "incumbent": list(SEEDS)},
                "manual_gates": {"G7": "NOT RUN: physical Pixel", "G8": "NOT RUN: Tyler blind read"}})
            from gate.report import report
            verdict = report(out)
            write_json(out / "status.json", {"phase": "complete", "complete": True, "verdict": verdict, "benchmark_version": version})
            print(f"{verdict}: {out / 'report.md'}", flush=True)
        except Exception as error:
            (out / "summary.json").unlink(missing_ok=True)
            write_json(out / "status.json", {"phase": phase, "complete": False, "error": str(error), "benchmark_version": version})
            billing_note = ""
            if args.judge_credit_budget and phase in ("judge", "report"):
                path = out / "judge-provenance.json"
                paid = json.loads(path.read_text()) if path.exists() else {}
                billing_note = (f"\nJudge credits spent (recorded): {paid['credits_spent']:g}; "
                                f"accounting complete: {paid['accounting_complete']}.\n"
                                if "judge_credit_budget" in paid else "\nJudge credit accounting unavailable; cost is unknown.\n")
            (out / "report.md").write_text(f"# Gate incomplete\n\nBenchmark version: {version}.\n\nRunner failed during {phase}: {error}\n\n"
                                           + "\n".join(f"- G{i}: FAIL (incomplete evidence)" for i in range(1, 7))
                                           + "\n- G7/G8: NOT RUN (manual).\n" + billing_note)
            raise


if __name__ == "__main__":
    main()
