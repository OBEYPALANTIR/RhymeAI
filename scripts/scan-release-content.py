#!/usr/bin/env python3
"""Scan release content without extracting files or printing matched secrets."""
import argparse
import sys
import zipfile


def scan_stream(stream, secret=b""):
    tail = b""
    while chunk := stream.read(1024 * 1024):
        data = tail + chunk
        if b"AI" + b"za" in data or (secret and secret in data):
            raise ValueError("content contains a Gemini key prefix")
        tail = data[-max(3, len(secret) - 1):]


def scan(path, binary=False, secret=b""):
    if binary:
        with open(path, "rb") as stream:
            scan_stream(stream, secret)
    else:
        with zipfile.ZipFile(path) as archive:
            for entry in archive.infolist():
                with archive.open(entry) as stream:
                    scan_stream(stream, secret)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", action="store_true", help="scan raw binaries instead of ZIP package entries")
    parser.add_argument("--secret-stdin", action="store_true", help="also reject exact secret bytes supplied on stdin")
    parser.add_argument("paths", nargs="+")
    args = parser.parse_args()
    secret = sys.stdin.buffer.read(65537) if args.secret_stdin else b""
    if args.secret_stdin and (not secret or len(secret) > 65536):
        print("Release content scan failed: invalid secret input.", file=sys.stderr)
        return 1
    for path in args.paths:
        try:
            scan(path, args.binary, secret)
        except (OSError, ValueError, zipfile.BadZipFile, RuntimeError, NotImplementedError):
            print("Release content scan failed: key pattern or unreadable input.", file=sys.stderr)
            return 1
    print("Release content key scan passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
