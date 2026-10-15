"""Explicit offline raw-token replay; never generate tokens or call a judge."""
from __future__ import annotations

import argparse
import fcntl
import json
import shutil
import subprocess
import time
from pathlib import Path

from .build import REPO, read_jsonl, sha256, write_json
from .generate import SAMPLER, SHIPPED_INCUMBENT_SHA256, gradle, select_incumbent, source_binding
from .judge import make_pairs
from .report import report
from .backend import read_binding, require_same_backend

GATE_TEST = "android/app/src/test/kotlin/com/rhymeai/app/service/LocalModelGateTest.kt"
ROLES = ("candidate", "incumbent")


def replay_binding(out, role):
    binding = json.loads((out / f"binding-{role}.json").read_text())
    current = source_binding()
    if not binding["source"].get(GATE_TEST):
        raise ValueError("Offline recheck requires the original gate-test source binding")
    changed = {k for k in current.keys() | binding["source"].keys() if current.get(k) != binding["source"].get(k)}
    if changed - {GATE_TEST}:
        raise ValueError("Offline recheck only permits a gate-test source change")
    model = Path(binding["model_path"])
    if (model.stat().st_size != binding["model_bytes"] or sha256(model) != binding["model_sha256"]
            or sha256(out / "prompts.json") != binding["prompts_sha256"]
            or binding["sampler"] != SAMPLER or json.loads((out / "sampler.json").read_text()) != SAMPLER):
        raise ValueError("Offline recheck inputs differ from the original binding")
    if role == "incumbent" and binding["model_sha256"] not in SHIPPED_INCUMBENT_SHA256:
        raise ValueError("Offline recheck incumbent is not a shipped GGUF")
    return dict(binding, source=current, sampler_seed_offset=binding.get("sampler_seed_offset", 0))


def verify_unchanged(out, hashes):
    for name, expected in hashes.items():
        if sha256(out / name) != expected:
            raise ValueError(f"Offline recheck input bytes changed: {name}")


def recheck(out):
    out = Path(out).resolve(strict=True)
    with (out / "run.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        archive = out / "evidence" / f"recheck-{time.time_ns()}"
        before, stage = archive / "before", archive / "replayed"
        before.mkdir(parents=True)
        stage.mkdir()
        # Preserve the previous verdict before invalidating it, even if validation fails.
        for name in ("summary.json", "report.md", "status.json"):
            shutil.copy2(out / name, before / name)
        for name in ("summary.json", "report.md"):
            (out / name).unlink()
        write_json(out / "status.json", {"phase": "offline-recheck", "complete": False})
        old_summary = json.loads((before / "summary.json").read_text())
        proof = {"complete": False, "mode": "offline raw-token replay; no inference or judge calls",
                 "before_verdict": old_summary["verdict"], "before_gates": old_summary["gates"],
                 "source_head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, text=True).strip()}
        (out / "RECHECK.md").write_text(f"# Offline recheck in progress\n\nBefore: {old_summary['verdict']}. After: INCOMPLETE.\n")
        try:
            if not json.loads((before / "status.json").read_text())["complete"]:
                raise ValueError("Offline recheck requires a previously completed run")
            names = ["benchmark.json", "benchmark-songs.jsonl", "inputs.json", "prompts.json", "parity.jsonl",
                     "sampler.json", "overlap-final.json", "pairs.jsonl", "judgments.jsonl", "judge-provenance.json", "provenance.json"]
            names += [f"{kind}-{role}.{suffix}" for role in ROLES
                      for kind, suffix in (("binding", "json"), ("raw", "jsonl"), ("replay", "jsonl"))]
            for role in ROLES:
                if "backend" not in json.loads((out / f"binding-{role}.json").read_text()):
                    names.append(f"evidence/props-{role}.json")
                    names.extend(str(path.relative_to(out)) for path in sorted((out / "evidence").glob(f"server-{role}-*-command.json")))
            hashes = {name: sha256(out / name) for name in names}
            proof["input_sha256"] = hashes
            for name in names:
                (before / name).parent.mkdir(parents=True, exist_ok=True)
                (stage / name).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(out / name, before / name)
                shutil.copy2(out / name, stage / name)
            verify_unchanged(before, hashes)
            verify_unchanged(stage, hashes)
            bindings = {role: replay_binding(stage, role) for role in ROLES}
            require_same_backend({role: read_binding(stage, role) for role in ROLES})
            select_incumbent(Path(bindings["candidate"]["model_path"]), Path(bindings["incumbent"]["model_path"]))
            proof["source_changes"] = {role: {"before": json.loads((before / f"binding-{role}.json").read_text())["source"],
                                                   "after": bindings[role]["source"]} for role in ROLES}
            write_json(archive / "recheck.json", proof)
            for role in ROLES:
                gradle(stage, "replay", role, seed_offset=bindings[role].get("sampler_seed_offset", 0))
            verify_unchanged(stage, hashes)
            verify_unchanged(out, hashes)
            changes = {}
            for role in ROLES:
                old = {(r["id"], r["seed"]): r for r in read_jsonl(before / f"replay-{role}.jsonl")}
                new = {(r["id"], r["seed"]): r for r in read_jsonl(stage / f"replayed-{role}.jsonl")}
                if new.keys() != old.keys():
                    raise ValueError("Offline replay coverage changed")
                changes[role] = {field: sum(old[k][field] != new[k][field] for k in old)
                                 for field in ("shown_lines", "calls", "decisions", "error")}
                changes[role]["rows_changed"] = sum(old[k] != new[k] for k in old)
                changes[role]["rows"] = len(new)
            proof["changes"] = changes
            if any(c["rows_changed"] for c in changes.values()):
                raise ValueError("Offline outputs/decisions changed; retained diffs cannot be certified with old live/judge evidence")
            for role in ROLES:
                shutil.copy2(stage / f"replayed-{role}.jsonl", stage / f"replay-{role}.jsonl")
                write_json(stage / f"binding-{role}.json", bindings[role])
            if make_pairs(stage) != read_jsonl(before / "pairs.jsonl"):
                raise ValueError("Blinded judge inputs changed; saved judgments cannot be reused")
            verdict = report(stage)
            summary = json.loads((stage / "summary.json").read_text())
            verify_unchanged(out, hashes)
            proof.update(complete=True, after_verdict=verdict, after_gates=summary["gates"],
                         byte_identical_inputs=True, identical_blinded_pairs=True,
                         judge_evidence="Saved judgments preserved byte-for-byte; legacy batch exit status is not invented",
                         report_sha256=sha256(stage / "report.md"), summary_sha256=sha256(stage / "summary.json"))
            write_json(archive / "recheck.json", proof)
            publish = ["report.md", "summary.json"] + [f"{kind}-{role}.{suffix}" for role in ROLES
                       for kind, suffix in (("binding", "json"), ("replay", "jsonl"), ("graded", "json"), ("generation-audit", "json"))]
            for name in publish:
                shutil.copy2(stage / name, out / name)
            lines = ["# Offline raw-token recheck", "", f"Before: **{old_summary['verdict']}**. After: **{verdict}**.", "",
                     "Saved raw chunks were replayed through the current Kotlin gate with every GGUFPromptFormat stop marker.",
                     "No inference or judge calls. Model, prompt, sampler and saved input bytes were verified before rebinding.", "",
                     "| Arm | Rows | Shown output changes | Retry changes | Decision changes | Error changes |",
                     "|---|---:|---:|---:|---:|---:|"]
            lines += [f"| {role} | {c['rows']} | {c['shown_lines']} | {c['calls']} | {c['decisions']} | {c['error']} |"
                      for role, c in changes.items()]
            lines += ["", f"Gates before: `{old_summary['gates']}`.", f"Gates after: `{summary['gates']}`.", "",
                      "Saved blinded pairs and judgments are unchanged. Original bindings, verdicts and input hashes are retained;",
                      "the explicit source rebind and Gradle/JUnit replay evidence are in "
                      f"[{archive.name}]({archive.relative_to(out)}/recheck.json).",
                      "Legacy judge batch exit statuses were not synthesized. Physical-device G7 and blind-read G8 remain NOT RUN."]
            (out / "RECHECK.md").write_text("\n".join(lines) + "\n")
            write_json(out / "status.json", {"phase": "complete", "complete": True, "verdict": verdict,
                                             "recheck": str(archive.relative_to(out) / "recheck.json")})
            print(f"{out.name}: {old_summary['verdict']} -> {verdict}; {changes}", flush=True)
        except BaseException as error:
            for name in ("summary.json", "report.md"):
                (out / name).unlink(missing_ok=True)
            proof.update(complete=False, error=str(error))
            write_json(archive / "recheck.json", proof)
            write_json(out / "status.json", {"phase": "offline-recheck", "complete": False, "error": str(error)})
            (out / "RECHECK.md").write_text(f"# Offline recheck incomplete\n\nBefore: {old_summary['verdict']}. After: INCOMPLETE.\n\n"
                                           f"{error}\n\nEvidence: [{archive.name}]({archive.relative_to(out)}/recheck.json).\n")
            raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path)
    recheck(parser.parse_args().out)
