#!/usr/bin/env python3
"""Scan release content without extracting files or printing matched secrets."""
import argparse
import sys
import zipfile


def scan_stream(stream):
    tail = b""
    while chunk := stream.read(1024 * 1024):
        data = tail + chunk
        if b"AI" + b"za" in data:
            raise ValueError("content contains a Gemini key prefix")
        tail = data[-3:]


def scan(path, binary=False):
    if binary:
        with open(path, "rb") as stream:
            scan_stream(stream)
    else:
        with zipfile.ZipFile(path) as archive:
            for entry in archive.infolist():
                with archive.open(entry) as stream:
                    scan_stream(stream)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", action="store_true", help="scan raw binaries instead of ZIP package entries")
    parser.add_argument("paths", nargs="+")
    args = parser.parse_args()
    for path in args.paths:
        try:
            scan(path, args.binary)
        except (OSError, ValueError, zipfile.BadZipFile, RuntimeError, NotImplementedError):
            print("Release content scan failed: key pattern or unreadable input.", file=sys.stderr)
            return 1
    print("Release content key scan passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
