"""CLI help and argument errors must work before loading provider credentials."""
import os
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

BIN = Path(__file__).resolve().parents[1] / "zig-out/bin/nib"


class CliTests(unittest.TestCase):
    def test_help_without_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            env = dict(os.environ, NIB_PROVIDER="invalid", NIB_HOME=directory)
            for args in (["--help"], ["-h"], ["ask", "--help"]):
                result = subprocess.run([str(BIN), *args], env=env, capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("Usage:", result.stdout)
                self.assertIn("Ctrl+O", result.stdout)
                self.assertEqual(result.stderr, "")
            for args in (["--x"], ["ask", "--x"], ["ask", "prompt", "--x"]):
                result = subprocess.run([str(BIN), *args], env=env, capture_output=True, text=True, timeout=5)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stderr, "nib: Unknown option: --x · run nib --help\n")

    def test_machine_error_code_stays_stable(self):
        result = subprocess.run([str(BIN), "ask", "--json"], capture_output=True, text=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["error"]["message"], "MissingPrompt")
        self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    unittest.main()
