#!/usr/bin/python
"""Exercise retargeting, exact final values and process exit with a fake backlight."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/brightness-transition'
WORKER = '''
from importlib.machinery import SourceFileLoader
from pathlib import Path
import sys
module = SourceFileLoader('brightness_transition', sys.argv[1]).load_module()
module.transition('test', float(sys.argv[3]), .18, sys_root=Path(sys.argv[2]), apply=lambda raw: None)
'''

class BrightnessTransitionTests(unittest.TestCase):
    def start(self, target, initial=200):
        work = tempfile.TemporaryDirectory()
        self.addCleanup(work.cleanup)
        path = Path(work.name) / 'test'
        path.mkdir()
        (path / 'max_brightness').write_text('1000')
        (path / 'brightness').write_text(str(initial))
        process = subprocess.Popen([sys.executable, '-B', '-c', WORKER, str(SCRIPT), work.name, str(target)],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: process.poll() is None and process.kill())
        return process

    def finish(self, process):
        output, error = process.communicate(timeout=2)
        self.assertEqual(process.returncode, 0, error)
        return [json.loads(line)['raw'] for line in output.splitlines()]

    def test_gradual_monotonic_and_exact_final_value(self):
        values = self.finish(self.start(70))
        self.assertGreater(len(set(values)), 4)
        self.assertEqual(values, sorted(values))
        self.assertEqual(values[-1], 700)
        self.assertTrue(all(200 <= value <= 700 for value in values))

    def test_retarget_during_animation_uses_latest_target(self):
        process = self.start(80)
        first = json.loads(process.stdout.readline())['raw']
        self.assertGreater(first, 200)
        process.stdin.write('60\n10\n')
        process.stdin.flush()
        values = self.finish(process)
        self.assertEqual(values[-1], 100)
        self.assertTrue(all(100 <= value <= 800 for value in values))

    def test_idle_helper_exits_even_with_stdin_open(self):
        process = self.start(20)
        process.wait(timeout=1)
        self.assertEqual(process.returncode, 0)
        self.assertEqual(self.finish(process)[-1], 200)

    def test_half_raw_step_matches_qml_rounding(self):
        self.assertEqual(self.finish(self.start(20.05))[-1], 201)

    def test_bounds(self):
        self.assertEqual(self.finish(self.start(-5))[-1], 10)
        self.assertEqual(self.finish(self.start(200))[-1], 1000)

    def test_non_finite_target_is_rejected(self):
        process = self.start('nan')
        _, error = process.communicate(timeout=2)
        self.assertNotEqual(process.returncode, 0)
        self.assertIn('Invalid brightness', error)

if __name__ == '__main__':
    unittest.main()
