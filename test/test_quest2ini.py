#!/usr/bin/env python3
"""Regressões do conversor, só com registros sintéticos, sem conexão ao console."""
import base64
import json
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


class Quest2IniTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build_dir = tempfile.TemporaryDirectory(prefix="p5m-converter-build-")
        cls.binary = Path(cls.build_dir.name) / "quest2ini"
        root = Path(__file__).resolve().parents[1]
        flags = shlex.split(subprocess.check_output(
            ["pkg-config", "--cflags", "--libs", "Qt6Core"], text=True))
        subprocess.run(["clang++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
                        str(root / "mac/quest2ini.cpp"), "-o", str(cls.binary), *flags], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.build_dir.cleanup()

    def setUp(self):
        self.files = tempfile.TemporaryDirectory(prefix="p5m-converter-case-")
        self.addCleanup(self.files.cleanup)
        self.source = Path(self.files.name) / "input.json"
        self.dest = Path(self.files.name) / "output.ini"
        dummy = base64.b64encode(bytes(range(16))).decode()
        self.host = {"target": "PS5_1", "server_mac": "02:00:00:00:00:01",
                     "rp_regist_key": dummy, "rp_key": dummy, "server_nickname": "Synthetic test"}

    def convert(self, content):
        self.source.write_text(content)
        return subprocess.run([str(self.binary), str(self.source), str(self.dest)],
                              capture_output=True, text=True)

    def document(self, hosts):
        return json.dumps({"settings": {"registered_hosts": hosts}})

    def test_invalid_json_preserves_existing(self):
        old = b"synthetic previous settings"
        self.dest.write_bytes(old)
        self.assertNotEqual(self.convert("{").returncode, 0)
        self.assertEqual(self.dest.read_bytes(), old)

    def test_valid_input_refuses_overwrite(self):
        old = b"synthetic previous settings"
        self.dest.write_bytes(old)
        self.assertNotEqual(self.convert(self.document([self.host])).returncode, 0)
        self.assertEqual(self.dest.read_bytes(), old)

    def test_invalid_input_creates_no_output(self):
        for content in ("{", "[]", self.document([]), self.document([dict(self.host, server_mac="bad")]),
                        self.document([dict(self.host, rp_key="invalid base64!")])):
            with self.subTest(content_kind=content[:10]):
                self.assertNotEqual(self.convert(content).returncode, 0)
                self.assertFalse(self.dest.exists())

    def test_invalid_second_console_creates_no_partial_output(self):
        self.assertNotEqual(self.convert(self.document([self.host, dict(self.host, target="UNKNOWN")])).returncode, 0)
        self.assertFalse(self.dest.exists())

    def test_valid_output_is_private_and_complete(self):
        result = self.convert(self.document([self.host]))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.dest.stat().st_mode & 0o777, 0o600)
        data = self.dest.read_text()
        self.assertIn("size=1", data)
        self.assertIn("target=1000100", data)
        self.assertEqual(sorted(p.name for p in self.dest.parent.iterdir()), ["input.json", "output.ini"])

    def test_missing_directory_fails_without_output(self):
        self.dest = self.dest.parent / "missing" / "output.ini"
        self.assertNotEqual(self.convert(self.document([self.host])).returncode, 0)
        self.assertFalse(self.dest.exists())


if __name__ == "__main__":
    unittest.main()
