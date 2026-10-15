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
FROZEN_VERSION = "rhymeai-gate-v1"
V2_VERSION = "rhymeai-gate-v2"
DEV_VERSION = "rhymeai-dev"


def frozen_path(version):
    return HERE / {FROZEN_VERSION: "frozen.json", V2_VERSION: "frozen-v2.json"}[version]


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


def audit_overlap(songs, include_frozen=False, benchmark="v1"):
    roots = [ARTIFACTS / "2026-10-07/rhymeai-teacher-data-v3",
             ARTIFACTS / "2026-10-08/rhymeai-colab-package-levels"]
    for root in roots:
        if not root.is_dir():
            raise FileNotFoundError(f"Required training pool unavailable: {root}")
    # Every teacher-data and Colab package directory is a training pool, including future versions.
    roots.extend(sorted({*ARTIFACTS.glob("*/rhymeai-teacher-data*"), *ARTIFACTS.glob("*/rhymeai-colab-package*")} - set(roots)))
    paths = set()
    for root in roots:
        # Include Python string pools as well as contexts, outputs and packaged splits.
        paths.update(p for p in root.rglob("*") if p.suffix in (".jsonl", ".json", ".py") and p.is_file())
    paths.update([REPO / "finetune/data/seed_songs.py", REPO / "finetune/eval/cases.py"])
    if include_frozen:
        paths.add(HERE / "benchmark-songs.jsonl")
        paths.add(HERE / "benchmark-songs-v2.jsonl")
    if benchmark == "v2":
        paths.add(HERE / "benchmark-songs.jsonl")
        paths.add(ARTIFACTS / "2026-10-14/rhymeai-round2/dev-songs.jsonl")
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
    audit = {"overlapping_lines": len(hits), "files": results, "pools": [str(root) for root in roots],
             "normalization": "lowercase ASCII word tokens; apostrophes normalized; contiguous 8-grams within each decoded line"}
    if include_frozen:
        audit["frozen_benchmark_sha256"] = sha256(HERE / "benchmark-songs.jsonl")
    return audit


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


def make_v2_inputs(songs):
    from .metrics import FUNCTION_WORDS

    rows = [r for r in make_inputs(songs) if r["task"] == "suggestions"]
    for i, song in enumerate(songs):
        suggestion = rows[i * 8]
        common = {key: suggestion["inputs"][key] for key in ("lyrics", "current_section", "selection_start")}
        base = {"song_id": song["id"], "level": LEVELS[i % 3], "rhyme_type": "NEW_SOUND"}
        words, endings = [], []
        for line in song["lines"][:2]:
            tokens = list(re.finditer(r"[A-Za-z]+(?:['\u2019][A-Za-z]+)*", line))
            # Frozen v2 retains "Each"/"One" from this list; v3 must exclude determiners (GATE.md).
            content = next(t for t in tokens if t.group().lower() not in FUNCTION_WORDS)
            for pool, token in ((words, content), (endings, tokens[-1])):
                position = common["lyrics"].index(line) + token.start()
                pool.append((token.group(), line, len(common["lyrics"][:position].encode("utf-16-le")) // 2))
        for action in ("REPHRASE", "PUNCH_UP", "HARDER_RHYME"):
            rows.append(dict(base, id=f"{song['id']}-rewrite_passage-{action}", task="rewrite_passage",
                             inputs=dict(common, action=action, selection="\n".join(song["lines"][:2]), rejected_candidates=[])))
            # Production accepts HARDER_RHYME only at line endings; other actions use content words.
            for number, (word, line, position) in enumerate(endings if action == "HARDER_RHYME" else words):
                rows.append(dict(base, id=f"{song['id']}-rewrite_word-{action}-{number}", task="rewrite_word",
                                 inputs=dict(common, action=action, selection=word, selection_start=position,
                                             rejected_candidates=["old", "new"] if (i + number) % 2 else [])))
        for number, (word, line, position) in enumerate(words):
            rows.append(dict(base, id=f"{song['id']}-synonyms-{number}", task="synonyms",
                             inputs=dict(common, word=word, line_context=line, limit=8)))
    for row in rows:
        row["inputs_sha256"] = text_hash(json.dumps(row["inputs"], sort_keys=True, ensure_ascii=False))
    return rows


def require_mode(out, version):
    manifest = out / "benchmark.json"
    if manifest.exists():
        if json.loads(manifest.read_text()).get("version") != version:
            raise ValueError("Cannot mix benchmark versions or DEV artifacts; use a separate output directory")
    elif version != FROZEN_VERSION and any(next(out.glob(pattern), None) is not None for pattern in
                                        ("inputs.json", "prompts.json", "benchmark-songs.jsonl", "binding-*.json",
                                         "raw-*.jsonl", "replay-*.jsonl", "summary.json", "pairs.jsonl", "judgments.jsonl")):
        raise ValueError("Unclassified artifacts cannot be adopted into a different benchmark directory")


def make_dev_inputs(songs, expanded_words=False):
    rows = make_inputs(songs)
    if not expanded_words:
        return rows
    from .metrics import FUNCTION_WORDS

    for song in songs[:20]:
        templates = [r for r in rows if r["song_id"] == song["id"] and r["task"] == "rewrite_word"]
        synonym = next(r for r in rows if r["song_id"] == song["id"] and r["task"] == "synonyms")
        lyrics = templates[0]["inputs"]["lyrics"]
        seen = {synonym["inputs"]["word"].lower()}
        selections, endings = [], []
        ending_seen = seen | {re.sub(r"[^a-z'\u2019]", "", word) for word in seen}
        for index, line in enumerate(song["lines"]):
            if line not in lyrics:
                continue
            matches = list(re.finditer(r"[A-Za-z]+(?:['\u2019][A-Za-z]+)*", line))
            for match in matches:
                word = match.group()
                position = lyrics.index(line) + match.start()
                selection = (word, line, len(lyrics[:position].encode("utf-16-le")) // 2)
                # Android rejects HARDER_RHYME on any word that does not end its line (AIService.kt
                # harderRhymeFitsContext), so that action only gets line-ending selections.
                if match is matches[-1] and word.lower() not in ending_seen and word.lower() not in FUNCTION_WORDS:
                    ending_seen.add(word.lower())
                    endings.append(selection)
                if index < 4 and word.lower() not in seen and word.lower() not in FUNCTION_WORDS:
                    seen.add(word.lower())
                    selections.append(selection)
        for template in templates:
            pool = endings if template["inputs"]["action"] == "HARDER_RHYME" else selections
            for number, (word, line, position) in enumerate(pool[:4], 1):
                rows.append(dict(template, id=f"{template['id']}-word-{number}",
                                 inputs=dict(template["inputs"], selection=word, selection_start=position)))
        for number, (word, line, position) in enumerate(selections[:5], 1):
            rows.append(dict(synonym, id=f"{synonym['id']}-word-{number}",
                             inputs=dict(synonym["inputs"], word=word, line_context=line)))
    for row in rows:
        row["inputs_sha256"] = text_hash(json.dumps(row["inputs"], sort_keys=True, ensure_ascii=False))
    return rows


def prepare_dev(out, songs_path, expanded_words=False):
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    require_mode(out, DEV_VERSION)
    songs = read_jsonl(songs_path)
    if (not songs or any(not isinstance(s, dict) or not all(isinstance(s.get(k), str) and s[k].strip() for k in ("id", "title", "theme"))
                         or not isinstance(s.get("lines"), list) or len(s["lines"]) < 4
                         or any(not isinstance(line, str) or not line.strip() for line in s["lines"]) for s in songs)
            or len({s["id"] for s in songs}) != len(songs)):
        raise ValueError("DEV songs require unique IDs, title/theme and at least four nonempty lyric lines")
    inputs = make_dev_inputs(songs, expanded_words)
    target = out / "inputs.json"
    if target.exists() and json.loads(target.read_text()) != inputs:
        raise ValueError("DEV inputs changed; use a separate output directory")
    # Persist the mode before artifacts so an interrupted DEV preparation cannot become a frozen run.
    write_json(out / "benchmark.json", {"version": DEV_VERSION})
    write_jsonl(out / "benchmark-songs.jsonl", songs)
    write_json(target, inputs)
    audit = audit_overlap(songs, include_frozen=True)
    write_json(out / "overlap.json", audit)
    manifest = {"version": DEV_VERSION, "seeds": SEEDS, "songs": len(songs), "prompts": len(inputs),
                "task_counts": dict(Counter(r["task"] for r in inputs)), "songs_sha256": sha256(out / "benchmark-songs.jsonl"),
                "inputs_sha256": sha256(target), "overlapping_lines": audit["overlapping_lines"]}
    if expanded_words:
        manifest["expanded_words"] = True
    write_json(out / "benchmark.json", manifest)
    if audit["overlapping_lines"]:
        raise ValueError(f"DEV contamination: {audit['overlapping_lines']} overlapping lines in frozen benchmark/training pools")
    return manifest


def freeze(out, benchmark="v1"):
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    version = {"v1": FROZEN_VERSION, "v2": V2_VERSION}[benchmark]
    require_mode(out, version)
    source = HERE / ("benchmark-songs.jsonl" if benchmark == "v1" else "benchmark-songs-v2.jsonl")
    songs = read_jsonl(source)
    inputs = make_inputs(songs) if benchmark == "v1" else make_v2_inputs(songs)
    target = out / "inputs.json"
    if (out / "prompts.json").exists() and json.loads(target.read_text()) != inputs:
        raise ValueError("Frozen inputs changed; use a new benchmark version/output directory")
    write_json(out / "benchmark.json", {"version": version})
    if benchmark == "v1":
        write_jsonl(out / "benchmark-songs.jsonl", songs)
    else:
        (out / "benchmark-songs.jsonl").write_bytes(source.read_bytes())
    write_json(target, inputs)
    audit = audit_overlap(songs, benchmark=benchmark)
    write_json(out / "overlap.json", audit)
    manifest = {"version": version, "seeds": SEEDS, "songs": len(songs), "prompts": len(inputs),
                "task_counts": dict(Counter(r["task"] for r in inputs)), "songs_sha256": sha256(out / "benchmark-songs.jsonl"),
                "inputs_sha256": sha256(target), "overlapping_lines": audit["overlapping_lines"]}
    frozen = json.loads(frozen_path(version).read_text())
    if any(manifest[key] != frozen[key] for key in ("songs", "songs_sha256", "inputs_sha256", "prompts", "task_counts")):
        raise ValueError(f"The {benchmark} benchmark is immutable; song/input hashes do not match {frozen_path(version).name}")
    write_json(out / "benchmark.json", manifest)
    if audit["overlapping_lines"]:
        raise ValueError(f"Benchmark contamination: {audit['overlapping_lines']} overlapping lines")
    return manifest


if __name__ == "__main__":
    import argparse
    import sys
    sys.path.insert(0, str(HERE.parent))
    from gate.build import freeze

    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    parser.add_argument("--benchmark", choices=("v1", "v2"), default="v1")
    args = parser.parse_args()
    print(json.dumps(freeze(args.out, args.benchmark), indent=2))
