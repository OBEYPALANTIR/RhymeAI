#!/usr/bin/env python3
"""Write shared/fixtures/archive-names-v1.json, the golden export-archive names (A39).

Standard library only. Android (BackupArchive.exportNames) and iOS must allocate the
same archive path for every recording:

- Within one song, recordings are visited by precedence time ascending, ties by id
  ascending (byte-wise UTF-8).
- The display name is sanitized: "/" and "\\" become "_", and each leading "." becomes "_".
- It splits into stem and extension at its last "." (none when there is no dot).
- Each recording takes "<stem><ext>"; when that is taken, "<stem> 2<ext>", "<stem> 3<ext>",
  ... (the first free counter from 2). Nothing is reserved ahead of its turn.
- "Taken" compares names NFC-normalized and case-folded.
- Before suffixing, the stem is cut so the whole UTF-8 name is at most 240 bytes,
  never splitting a code point.
- The archive path is "recordings/<projectId>/<name>". Import finds each file by
  recording id through the manifest and this same allocation, never by name alone.

Usage: python3 scripts/generate-archive-names-fixture.py [--check]
"""

import argparse
import json
import sys
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURE = ROOT / "shared" / "fixtures" / "archive-names-v1.json"
MAX_NAME_BYTES = 240


def sanitize(name: str) -> str:
    name = name.replace("/", "_").replace("\\", "_")
    stripped = name.lstrip(".")
    return "_" * (len(name) - len(stripped)) + stripped


def fit(text: str, max_bytes: int) -> str:
    out = text
    while len(out.encode("utf-8")) > max_bytes:
        out = out[:-1]
    return out


def key(name: str) -> str:
    return unicodedata.normalize("NFC", name).casefold()


def allocate(entries):
    names = {}
    by_song = {}
    for entry in entries:
        by_song.setdefault(entry["projectId"], []).append(entry)
    for project_id, song in by_song.items():
        taken = set()
        for entry in sorted(song, key=lambda e: (e["precedenceTime"], e["id"].encode("utf-8"))):
            name = sanitize(entry["displayName"])
            dot = name.rfind(".")
            stem, ext = (name[:dot], name[dot:]) if dot > 0 else (name, "")
            n = 1
            while True:
                suffix = "" if n == 1 else f" {n}"
                candidate = fit(stem, MAX_NAME_BYTES - len((suffix + ext).encode("utf-8"))) + suffix + ext
                if key(candidate) not in taken:
                    break
                n += 1
            taken.add(key(candidate))
            names[entry["id"]] = f"recordings/{project_id}/{candidate}"
    return names


def entry(n: int, project: str, time: int, display: str) -> dict:
    return {"id": f"00000000-0000-4000-8000-{n:012d}", "projectId": project, "precedenceTime": time, "displayName": display}


def build() -> dict:
    long_stem = "é" * 125  # 250 UTF-8 bytes
    inputs = [
        # take, take, "take 2": nothing is reserved ahead of its turn.
        entry(1, "song-a", 1000, "take.m4a"),
        entry(2, "song-a", 2000, "take.m4a"),
        entry(3, "song-a", 3000, "take 2.m4a"),
        # A case-only collision, and an accented one in decomposed form.
        entry(4, "song-b", 1000, "Take.m4a"),
        entry(5, "song-b", 2000, "take.m4a"),
        entry(6, "song-b", 3000, "Café.m4a"),
        entry(7, "song-b", 4000, "CAFÉ.m4a"),
        # Unicode truncation, with and without a suffix.
        entry(8, "song-c", 1000, long_stem + ".m4a"),
        entry(9, "song-c", 2000, long_stem + ".m4a"),
        # Separators and leading dots.
        entry(10, "song-d", 1000, "../verse/idea.m4a"),
        entry(11, "song-d", 2000, ".hidden.m4a"),
        entry(12, "song-d", 3000, "no extension"),
        # A tie in time: the smaller id goes first.
        entry(14, "song-e", 5000, "hook.m4a"),
        entry(13, "song-e", 5000, "hook.m4a"),
        # The same name in another song is free there.
        entry(15, "song-f", 1000, "take.m4a"),
    ]
    names = allocate(inputs)
    return {
        "description": "A39 export-archive names; see scripts/generate-archive-names-fixture.py for the rule.",
        "maxNameBytes": MAX_NAME_BYTES,
        "cases": [dict(e, archivePath=names[e["id"]]) for e in inputs],
    }


def render() -> str:
    return json.dumps(build(), ensure_ascii=False, indent=2) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="fail if the fixture on disk differs")
    args = parser.parse_args()
    text = render()
    if args.check:
        if not FIXTURE.is_file() or FIXTURE.read_text(encoding="utf-8") != text:
            print(f"{FIXTURE.relative_to(ROOT)} is out of date; rerun without --check", file=sys.stderr)
            return 1
        print("archive-names-v1 fixture is current")
        return 0
    FIXTURE.write_text(text, encoding="utf-8")
    print(f"wrote {FIXTURE.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
