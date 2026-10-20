#!/usr/bin/env python3
"""Recover synthetic native-format examples into disjoint teacher-pilot splits."""

import argparse
import collections
import hashlib
import html
import json
import re
import tarfile
from pathlib import Path

MEMBERS = {
    "./training-pair/native/train.jsonl": "4f36cadd9c44ea17d46d0ade6e09e7e320e7f5a9b7ccf6ae3d1806ee71cb5da2",
    "./training-pair/native/val.jsonl": "d49f80832d904762464e9cd9ddd6b8d20978d79da547580b81034c7d388f2520",
}
START = "<|turn>user\n"
BOUNDARY = "<turn|>\n<|turn>model\n"
END = "<turn|>"
TASKS = {"suggestions", "rewrite_passage", "rewrite_word", "synonyms"}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def normalized(text):
    return " ".join(re.findall(r"[a-z0-9]+", text.casefold()))


def quoted_field(prompt, label):
    match = re.search(re.escape(label) + r'\s*"""\s*(.*?)\s*"""', prompt, re.S)
    return match.group(1).strip() if match else ""


def parse_row(row):
    text = row["text"]
    if not text.startswith(START) or text.count(BOUNDARY) != 1 or not text.endswith(END):
        raise ValueError("Unexpected archived chat serialization")
    prompt, completion = text[len(START):-len(END)].split(BOUNDARY)
    if row["task"] not in TASKS or not prompt.strip() or not completion.strip():
        raise ValueError("Missing prompt/completion or unsupported task")
    context = quoted_field(prompt, "Lyrics context:")
    if row["task"] == "synonyms":
        target = re.search(r"<target>(.*?)</target>", prompt, re.S)
        if not target:
            raise ValueError("Synonym example has no target")
        # Different contexts for one synonym target remain in the same split.
        group = "word:" + normalized(html.unescape(target.group(1)))
    elif context:
        group = "lyrics:" + normalized(context)
    else:
        raise ValueError("Writing example has no source lyric context")
    return {"prompt": prompt, "completion": completion.strip(), "task": row["task"],
            "source_case": row.get("case_seed", ""), "group": digest(group.encode()),
            "prompt_sha256": digest(normalized(prompt).encode())}


def reject_reason(row):
    answer, task = row["completion"], row["task"]
    if re.search(r"<\|?|\|>|(?:^|\n)_?(?:response|output)\s*>?", answer, re.I):
        return "control_marker"
    lines = [line.strip() for line in answer.splitlines() if line.strip()]
    if task == "suggestions":
        if len(lines) != 6 or len({normalized(line) for line in lines}) != 6:
            return "suggestion_count_or_duplicates"
        existing = {normalized(line) for line in quoted_field(row["prompt"], "Lyrics context:").splitlines()}
        if any(normalized(line) in existing for line in lines):
            return "copied_lyric_line"
    if task in {"synonyms", "rewrite_word"}:
        if any(not re.fullmatch(r"[A-Za-z]+(?:['’-][A-Za-z]+)*", line) for line in lines):
            return "word_format"
        if task == "rewrite_word" and len(lines) != 1:
            return "word_count"
        if task == "synonyms":
            if not 3 <= len(lines) <= 8 or len({normalized(line) for line in lines}) != len(lines):
                return "synonym_count_or_duplicates"
            target = re.search(r"<target>(.*?)</target>", row["prompt"], re.S).group(1)
            if normalized(target) in {normalized(line) for line in lines}:
                return "returned_target"
    return None


def split_rows(rows, salt="rhymeai-12b-teacher-20261004"):
    # Union exact input prompts as well as source contexts, so task variants
    # cannot put the same input on both sides of the evaluation boundary.
    parent = {}

    def find(key):
        parent.setdefault(key, key)
        if parent[key] != key:
            parent[key] = find(parent[key])
        return parent[key]

    for row in rows:
        a, b = find("g:" + row["group"]), find("p:" + row["prompt_sha256"])
        parent[max(a, b)] = min(a, b)
    result = {"train": [], "validation": [], "test": []}
    for row in rows:
        root = find("g:" + row["group"])
        bucket = int(digest((salt + root).encode())[:8], 16) % 100
        split = "test" if bucket < 10 else "validation" if bucket < 20 else "train"
        result[split].append(row)
    for a, b in (("train", "validation"), ("train", "test"), ("validation", "test")):
        for key in ("group", "prompt_sha256"):
            if {r[key] for r in result[a]} & {r[key] for r in result[b]}:
                raise ValueError("Split leakage")
    return result


def prepare(archive, output):
    output = Path(output)
    output.mkdir(parents=True, exist_ok=False)
    rows, rejected, seen = [], collections.Counter(), set()
    with tarfile.open(archive) as source:
        for member, expected in MEMBERS.items():
            content = source.extractfile(member).read()
            if digest(content) != expected:
                raise ValueError("Archived dataset hash mismatch: " + member)
            for line in content.splitlines():
                row = parse_row(json.loads(line))
                reason = reject_reason(row)
                key = (row["prompt"], row["completion"])
                if reason or key in seen:
                    rejected[reason or "exact_duplicate"] += 1
                    continue
                seen.add(key)
                rows.append(row)
    splits = split_rows(rows)
    manifest = {"schema": "rhymeai-teacher-data-v1", "sources": MEMBERS,
                "rejected": dict(rejected), "split_unit": "normalized lyric context or synonym target, unioned by exact prompt",
                "limitations": ["Synthetic archived examples; semantic quality is not established by structural filtering.",
                                "Exact context/input separation does not establish broader stylistic independence."],
                "splits": {}}
    for name, values in splits.items():
        counts = collections.Counter(r["task"] for r in values)
        if any(counts[task] < 8 for task in TASKS):
            raise ValueError("Insufficient per-task split coverage: " + name)
        data = "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in values).encode()
        (output / (name + ".jsonl")).write_bytes(data)
        manifest["splits"][name] = {"rows": len(values), "tasks": dict(counts),
                                   "groups": len({r["group"] for r in values}), "sha256": digest(data)}
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    print(json.dumps(prepare(args.archive, args.out), indent=2))
