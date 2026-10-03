#!/usr/bin/env python3
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

SCANNER = Path(__file__).with_name("scan-release-content.py")


class ReleaseArchiveTests(unittest.TestCase):
    def scan(self, payload, compression):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "release.apk"
            with zipfile.ZipFile(archive, "w", compression=compression) as package:
                package.writestr("assets/payload", payload)
            return subprocess.run([sys.executable, str(SCANNER), str(archive)], capture_output=True)

    def test_clean_compressed_package(self):
        self.assertEqual(self.scan(b"benign payload", zipfile.ZIP_DEFLATED).returncode, 0)

    def test_compressed_key_marker_is_rejected_without_disclosure(self):
        marker = b"AI" + b"za" + b"synthetic_not_a_real_credential"
        result = self.scan(b"x" * 10000 + marker, zipfile.ZIP_DEFLATED)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn(marker, result.stdout + result.stderr)

    def test_key_marker_across_chunk_boundary(self):
        result = self.scan(b"x" * (1024 * 1024 - 2) + b"AI" + b"za", zipfile.ZIP_STORED)
        self.assertEqual(result.returncode, 1)

    def test_raw_binary_and_chunk_boundary(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "WritersBlock"
            binary.write_bytes(b"x" * (1024 * 1024 - 1) + b"AI" + b"za")
            result = subprocess.run([sys.executable, str(SCANNER), "--binary", str(binary)], capture_output=True)
            self.assertEqual(result.returncode, 1)
            binary.write_bytes(b"clean binary")
            result = subprocess.run([sys.executable, str(SCANNER), "--binary", str(binary)], capture_output=True)
            self.assertEqual(result.returncode, 0)

    def test_exact_stdin_secret_across_chunk_boundary(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "release.apk"
            marker = b"synthetic-exact-secret-without-provider-prefix"
            with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as package:
                package.writestr("payload", b"x" * (1024 * 1024 - 5) + marker)
            result = subprocess.run([sys.executable, str(SCANNER), "--secret-stdin", str(archive)], input=marker, capture_output=True)
            self.assertEqual(result.returncode, 1)
            self.assertNotIn(marker, result.stdout + result.stderr)
            result = subprocess.run([sys.executable, str(SCANNER), "--secret-stdin", str(archive)], input=b"", capture_output=True)
            self.assertEqual(result.returncode, 1)

    def test_missing_binary_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, str(SCANNER), "--binary", str(Path(directory) / "missing")], capture_output=True)
            self.assertEqual(result.returncode, 1)

    def test_invalid_archive_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "broken.aab"
            archive.write_bytes(b"not a zip")
            result = subprocess.run([sys.executable, str(SCANNER), str(archive)], capture_output=True)
            self.assertEqual(result.returncode, 1)


if __name__ == "__main__":
    unittest.main()
