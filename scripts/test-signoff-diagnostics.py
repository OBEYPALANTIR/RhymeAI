#!/usr/bin/env python3
"""Exercise sign-off credential diagnostics against real temporary Git repositories."""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("final-signoff-status.sh")


class SignoffDiagnosticsTests(unittest.TestCase):
    def run_signoff(self, payload, initialize=True):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            (root / "docs").mkdir()
            shutil.copyfile(SCRIPT, root / "scripts" / SCRIPT.name)
            for name in ("BUGS.md", "KNOWN_ISSUES.md", "PARITY.md", "README.md",
                         "RELEASE_NOTES.md", "docs/FINAL_SIGNOFF_STATUS.md"):
                (root / name).write_text("Temporary verification fixture.\n")
            (root / "fixture.txt").write_text(payload)
            env = os.environ.copy()
            for name in ("RUN_VERIFY", "RUN_PROVIDER_LIVE", "RUN_LOCAL_GGUF",
                         "RUN_CLOUDKIT_READINESS", "LOCAL_GGUF_PATH",
                         "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"):
                env.pop(name, None)
            env["GIT_CEILING_DIRECTORIES"] = str(root.parent)
            if initialize:
                subprocess.run(["git", "init", "-q", str(root)], env=env, check=True)
                subprocess.run(["git", "add", "fixture.txt"], cwd=root, env=env, check=True)
            return subprocess.run(["bash", str(root / "scripts" / SCRIPT.name)],
                                  cwd=root, env=env, capture_output=True, text=True)

    def test_clean_source_is_reported_without_claiming_live_acceptance(self):
        result = self.run_signoff("benign fixture")
        self.assertIn("PASS: tracked files contain no Gemini key prefix", result.stdout)
        self.assertEqual(result.returncode, 2)

    def test_detected_secret_is_never_printed(self):
        marker = "AI" + "za" + "synthetic_not_a_real_credential"
        result = self.run_signoff(marker)
        self.assertEqual(result.returncode, 2)
        self.assertIn("matching content withheld", result.stderr)
        self.assertNotIn(marker, result.stdout + result.stderr)
        self.assertNotIn("fixture.txt", result.stdout + result.stderr)

    def test_failed_git_scan_does_not_report_clean_source(self):
        result = self.run_signoff("benign fixture", initialize=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("tracked key scan could not complete", result.stderr)
        self.assertNotIn("PASS: tracked files contain no Gemini key prefix", result.stdout)


if __name__ == "__main__":
    unittest.main()
