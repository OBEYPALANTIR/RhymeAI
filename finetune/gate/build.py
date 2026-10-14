"""Freeze original inputs and audit every supplied training pool before inference."""
from __future__ import annotations

import ast
import hashlib
import json
import re
import time
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
ARTIFACTS = Path.home() / ".agents/artifacts"
SEEDS = (7000, 7001, 7002)
LEVELS = ("Simple", "Moderate", "Complex")
RHYMES = ("PERFECT", "NEAR", "SLANT", "NEW_SOUND")


def sha256(path):
    with Path(path).open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def text_hash(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def read_jsonl(path):
    with Path(path).open() as handle:
        return [json.loads(line) for line in handle if line.strip()]


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def write_jsonl(path, rows):
    Path(path).write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))


def grams(line, width=8):
    words = re.findall(r"[a-z0-9]+(?:'[a-z]+)?", line.lower().replace("\u2019", "'"))
    return {tuple(words[i:i + width]) for i in range(len(words) - width + 1)}


def strings(value):
    if isinstance(value, str):
        yield from value.splitlines()
    elif isinstance(value, dict):
        for item in value.values():
            yield from strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)


def pool_lines(path):
    if path.suffix == ".jsonl":
        with path.open() as handle:
            for line in handle:
                if line.strip():
                    yield from strings(json.loads(line))
    elif path.suffix == ".json":
        yield from strings(json.loads(path.read_text()))
    elif path.suffix == ".py":
        for node in ast.walk(ast.parse(path.read_text())):
            if isinstance(node, ast.Constant) and isinstance(node.value, str):
                yield from node.value.splitlines()


def overlapping_lines(songs, pool):
    index = {}
    for song in songs:
        for number, line in enumerate(song["lines"], 1):
            for gram in grams(line):
                index.setdefault(gram, set()).add((song["id"], number))
    hits = set()
    for line in pool:
        for gram in grams(line) & index.keys():
            hits.update(index[gram])
    return sorted(hits)


def audit_overlap(songs):
    roots = [ARTIFACTS / "2026-10-07/rhymeai-teacher-data-v3",
             ARTIFACTS / "2026-10-08/rhymeai-colab-package-levels"]
    for root in roots:
        if not root.is_dir():
            raise FileNotFoundError(f"Required training pool unavailable: {root}")
    v4 = ARTIFACTS / "2026-10-14/rhymeai-teacher-data-v4"
    if v4.exists():
        roots.append(v4)
    paths = set()
    for root in roots:
        # Include Python string pools as well as contexts, outputs and packaged splits.
        paths.update(p for p in root.rglob("*") if p.suffix in (".jsonl", ".json", ".py") and p.is_file())
    paths.update([REPO / "finetune/data/seed_songs.py", REPO / "finetune/eval/cases.py"])
    results = []
    hits = set()
    for path in sorted(paths):
        for attempt in range(3):
            before = sha256(path)
            try:
                found = overlapping_lines(songs, pool_lines(path))
            except (json.JSONDecodeError, SyntaxError):
                if before == sha256(path):
                    raise
                found = None
            if found is not None and before == sha256(path):
                break
            if attempt == 2:
                raise RuntimeError(f"Training pool changed during audit; rerun after writer settles: {path}")
            time.sleep(1)
        hits.update(found)
        results.append({"path": str(path), "sha256": before, "overlaps": found})
    return {"overlapping_lines": len(hits), "files": results, "v4_present": v4.exists(),
            "normalization": "lowercase ASCII word tokens; apostrophes normalized; contiguous 8-grams within each decoded line"}


def make_inputs(songs):
    rows = []
    actions = ("REPHRASE", "PUNCH_UP", "HARDER_RHYME")
    for i, song in enumerate(songs):
        section = ("VERSE", "CHORUS", "BRIDGE", "UNKNOWN")[i % 4]
        has_first = (i // 4) % 2 == 1
        active = "\n".join(song["lines"][:4])
        chorus = "[Chorus]\n" + "\n".join(song["lines"][4:])
        header = "" if section == "UNKNOWN" else f"[{section.title()}]\n"
        if section == "UNKNOWN":
            lyrics = active + ("\n\n" + chorus if has_first else "")
        else:
            lyrics = (chorus + "\n\n" if has_first else "") + header + active
        start = lyrics.index(song["lines"][0])
        section_ref = None if section == "UNKNOWN" else [section, 2 if section == "CHORUS" and has_first else 1]
        common = {"lyrics": lyrics, "current_section": section, "selection_start": start}
        for j in range(8):
            level = LEVELS[(i + j) % 3]
            rhyme = RHYMES[j % 4]
            inputs = dict(common, theme=song["theme"], target_rhyme_line=None if rhyme == "NEW_SOUND" else song["lines"][2],
                          rhyme_type="PERFECT" if rhyme == "NEW_SOUND" else rhyme, rhyme_scheme="AABB", current_letter="A",
                          complexity=level.upper(), use_whole_song_context=j % 2 == 0, section=section_ref,
                          cursor_line=lyrics[:start].count("\n") + 3)
            rows.append({"id": f"{song['id']}-suggest-{j}", "song_id": song["id"], "task": "suggestions",
                         "level": level, "rhyme_type": rhyme, "inputs": inputs})
        if i < 20:
            for action in actions:
                for task in ("rewrite_passage", "rewrite_word"):
                    selection = "\n".join(song["lines"][:2]) if task == "rewrite_passage" else song["lines"][0].split()[-1]
                    position = start if task == "rewrite_passage" else start + len(song["lines"][0]) - len(selection)
                    rejected = ["old", "new"] if task == "rewrite_word" and i % 2 else []
                    rows.append({"id": f"{song['id']}-{task}-{action}", "song_id": song["id"], "task": task,
                                 "level": LEVELS[i % 3], "rhyme_type": "NEW_SOUND",
                                 "inputs": dict(common, action=action, selection=selection, selection_start=position,
                                                rejected_candidates=rejected)})
        rows.append({"id": f"{song['id']}-synonyms", "song_id": song["id"], "task": "synonyms", "level": LEVELS[i % 3],
                     "rhyme_type": "NEW_SOUND", "inputs": dict(common, word=song["lines"][0].split()[-1],
                                                               line_context=song["lines"][0], limit=8)})
    for row in rows:
        row["inputs_sha256"] = text_hash(json.dumps(row["inputs"], sort_keys=True, ensure_ascii=False))
    return rows


def freeze(out):
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    songs = read_jsonl(HERE / "benchmark-songs.jsonl")
    inputs = make_inputs(songs)
    target = out / "inputs.json"
    if (out / "prompts.json").exists() and json.loads(target.read_text()) != inputs:
        raise ValueError("Frozen inputs changed; use a new benchmark version/output directory")
    write_jsonl(out / "benchmark-songs.jsonl", songs)
    write_json(target, inputs)
    audit = audit_overlap(songs)
    write_json(out / "overlap.json", audit)
    manifest = {"version": "rhymeai-gate-v1", "seeds": SEEDS, "songs": len(songs), "prompts": len(inputs),
                "task_counts": dict(Counter(r["task"] for r in inputs)), "songs_sha256": sha256(out / "benchmark-songs.jsonl"),
                "inputs_sha256": sha256(target), "overlapping_lines": audit["overlapping_lines"]}
    frozen = json.loads((HERE / "frozen.json").read_text())
    if any(manifest[key] != frozen[key] for key in ("songs_sha256", "inputs_sha256", "prompts", "task_counts")):
        raise ValueError("The v1 benchmark is immutable; song/input hashes do not match frozen.json")
    write_json(out / "benchmark.json", manifest)
    if audit["overlapping_lines"]:
        raise ValueError(f"Benchmark contamination: {audit['overlapping_lines']} overlapping lines")
    return manifest


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    print(json.dumps(freeze(parser.parse_args().out), indent=2))
