#!/usr/bin/env python3
"""Private history initialization and recovery; every test owns its /tmp state."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/launcher-state'


class LauncherHistoryTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix='launcher-history-')
        self.addCleanup(self.work.cleanup)
        self.path = Path(self.work.name) / 'private/launcher.json'

    def initialize(self):
        subprocess.run(['python3', str(SCRIPT), str(self.path)], check=True, timeout=5)

    def test_private_initialization_and_preservation(self):
        self.initialize()
        self.assertEqual(json.loads(self.path.read_text()), {'schemaVersion': 1, 'records': []})
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.path.parent.stat().st_mode & 0o777, 0o700)
        payload = {'schemaVersion': 1, 'records': [{'kind': 'file', 'id': '/tmp/example file.txt'}]}
        self.path.write_text(json.dumps(payload))
        self.initialize()
        self.assertEqual(json.loads(self.path.read_text()), payload)

    def test_corrupt_history_is_preserved_before_reset(self):
        self.path.parent.mkdir()
        for invalid in ['invalid json', '[1]', '{"schemaVersion":1,"records":null}',
                        '{"schemaVersion":2,"records":[]}']:
            self.path.write_text(invalid)
            self.initialize()
            self.assertEqual(json.loads(self.path.read_text())['records'], [])
            self.assertIn(invalid, [path.read_text() for path in self.path.parent.glob('*.corrupt-*')])

    def test_oversized_history_is_quarantined(self):
        self.path.parent.mkdir()
        self.path.write_bytes(b' ' * (1024 * 1024 + 1))
        self.initialize()
        self.assertEqual(json.loads(self.path.read_text())['records'], [])
        self.assertEqual(len(list(self.path.parent.glob('*.corrupt-*'))), 1)


if __name__ == '__main__':
    unittest.main()
