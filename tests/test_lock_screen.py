#!/usr/bin/env python3
"""Exercise lock orchestration with fake processes in private runtime directories."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LockScreenTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="qs-lock-helper-test-")
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.root = self.work / "config/quickshell"
        for relative in ("scripts", "integrations/LockObserver", "config"):
            (self.root / relative).mkdir(parents=True)
        self.bin = self.work / "bin"
        self.bin.mkdir()
        self.runtime = self.work / "runtime"
        self.runtime.mkdir(mode=0o700)
        self.state = self.work / "state"
        self.state.write_text("unlocked")
        shutil.copy2(ROOT / "scripts/lock-screen", self.root / "scripts/lock-screen")
        shutil.copy2(ROOT / "config/lock-fallback.conf", self.root / "config/lock-fallback.conf")
        self.env = dict(os.environ, PATH=str(self.bin), XDG_RUNTIME_DIR=str(self.runtime),
                        XDG_CONFIG_HOME=str(self.work / "config"), WAYLAND_DISPLAY="test-only-display",
                        QS_TEST_WORK=str(self.work), QS_TEST_QS="lock", QS_TEST_FALLBACK="lock")
        self.write_script(self.root / "integrations/LockObserver/lock-observer", '''
import os,pathlib,time
work=pathlib.Path(os.environ['QS_TEST_WORK'])
if os.environ.get('QS_TEST_OBSERVER') == 'error': raise SystemExit(1)
if os.environ.get('QS_TEST_OBSERVER') == 'hang': time.sleep(30)
state=(work/'state').read_text()
print('ready '+state, flush=True)
while True:
    next_state=(work/'state').read_text()
    if next_state != state:
        print(next_state, flush=True)
        state=next_state
    time.sleep(.01)
''')
        self.write_script(self.bin / "qs", '''
import json,os,pathlib,sys,time
work=pathlib.Path(os.environ['QS_TEST_WORK'])
with (work/'qs.calls').open('a') as log: log.write(json.dumps(sys.argv[1:])+'\\n')
mode=os.environ['QS_TEST_QS']
if mode == 'error': raise SystemExit(1)
if mode == 'hang': time.sleep(30)
if mode == 'lock':
    time.sleep(.2)
    (work/'state').write_text('locked')
''')
        self.write_script(self.bin / "hyprlock", '''
import json,os,pathlib,sys,time
work=pathlib.Path(os.environ['QS_TEST_WORK'])
with (work/'hyprlock.calls').open('a') as log: log.write(json.dumps({'pid':os.getpid(),'argv':sys.argv[1:]})+'\\n')
mode=os.environ['QS_TEST_FALLBACK']
if mode == 'error': raise SystemExit(1)
if mode == 'exit-zero': raise SystemExit(0)
if mode == 'lock':
    time.sleep(.15)
    (work/'state').write_text('locked')
time.sleep(30)
''')
        self.addCleanup(self.stop_fallbacks)

    def write_script(self, path, code):
        path.write_text("#!" + sys.executable + "\n" + code)
        path.chmod(0o755)

    def calls(self, name):
        path = self.work / (name + ".calls")
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def stop_fallbacks(self):
        for item in self.calls("hyprlock"):
            try:
                os.kill(item["pid"], signal.SIGKILL)
            except ProcessLookupError:
                pass

    def invoke(self):
        start = time.monotonic()
        result = subprocess.run([sys.executable, str(self.root / "scripts/lock-screen")],
                                env=self.env, capture_output=True, text=True, timeout=6)
        return result, time.monotonic() - start

    def test_waits_for_compositor_and_preserves_exact_config_argument(self):
        result, elapsed = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreaterEqual(elapsed, .2)
        self.assertLess(elapsed, 1.2)
        self.assertEqual(self.calls("qs"), [["ipc", "-p", str(self.root), "call", "lockscreen", "lock"]])
        self.assertEqual(self.calls("hyprlock"), [])

    def test_ack_without_secure_uses_fallback_and_disables_grace(self):
        self.env["QS_TEST_QS"] = "ack"
        result, elapsed = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreaterEqual(elapsed, 1.2)
        self.assertLess(elapsed, 2.0)
        calls = self.calls("hyprlock")
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["argv"], ["--config", str(self.root / "config/lock-fallback.conf"),
                                          "--grace", "0", "--immediate-render", "--no-fade-in", "--quiet"])

    def test_missing_qs_and_rejected_ipc_both_use_fallback(self):
        self.env["QS_TEST_QS"] = "error"
        result, elapsed = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(elapsed, 1.2)
        self.stop_fallbacks()
        self.state.write_text("unlocked")
        (self.bin / "qs").unlink()
        result, elapsed = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(elapsed, 1.2)

    def test_hung_ipc_is_bounded(self):
        self.env["QS_TEST_QS"] = "hang"
        result, elapsed = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreaterEqual(elapsed, 1.2)
        self.assertLess(elapsed, 2.0)

    def test_already_secure_does_not_contact_a_locker(self):
        self.state.write_text("locked")
        result, elapsed = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(elapsed, .6)
        self.assertEqual(self.calls("qs"), [])
        self.assertEqual(self.calls("hyprlock"), [])

    def test_concurrent_requests_share_one_fallback(self):
        self.env["QS_TEST_QS"] = "error"
        children = [subprocess.Popen([sys.executable, str(self.root / "scripts/lock-screen")],
                                    env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    for _ in range(8)]
        for child in children:
            _, error = child.communicate(timeout=6)
            self.assertEqual(child.returncode, 0, error)
        self.assertEqual(len(self.calls("hyprlock")), 1)
        self.assertEqual(len(self.calls("qs")), 1)

    def test_missing_fallback_is_a_failure(self):
        self.env["QS_TEST_QS"] = "error"
        (self.bin / "hyprlock").unlink()
        result, elapsed = self.invoke()
        self.assertEqual(result.returncode, 1)
        self.assertIn("Brak awaryjnego programu hyprlock", result.stderr)
        self.assertLess(elapsed, 1.2)

    def test_locker_exit_never_substitutes_for_compositor_confirmation(self):
        self.env["QS_TEST_QS"] = "error"
        for mode in ("error", "exit-zero"):
            with self.subTest(mode=mode):
                self.env["QS_TEST_FALLBACK"] = mode
                result, _ = self.invoke()
                self.assertEqual(result.returncode, 1)
                self.assertIn("bez potwierdzenia", result.stderr)

    def test_timeout_leaves_locker_alive_and_prevents_another_fallback(self):
        self.env.update(QS_TEST_QS="error", QS_TEST_FALLBACK="hang")
        result, elapsed = self.invoke()
        self.assertEqual(result.returncode, 1)
        self.assertGreaterEqual(elapsed, 4)
        self.assertLess(elapsed, 4.7)
        self.assertIn("hyprlock pozostaje uruchomiony", result.stderr)
        pid = self.calls("hyprlock")[0]["pid"]
        os.kill(pid, 0)
        result, elapsed = self.invoke()
        self.assertEqual(result.returncode, 1)
        self.assertLess(elapsed, 4.7)
        self.assertIn("Poprzednie żądanie", result.stderr)
        self.assertEqual(len(self.calls("hyprlock")), 1)
        os.kill(pid, 0)

    def test_unavailable_or_hung_observer_fails_without_false_success(self):
        for mode in ("error", "hang"):
            with self.subTest(mode=mode):
                self.env["QS_TEST_OBSERVER"] = mode
                result, elapsed = self.invoke()
                self.assertEqual(result.returncode, 1)
                self.assertLess(elapsed, 1.1)

    def test_private_runtime_is_required(self):
        self.runtime.chmod(0o755)
        result, _ = self.invoke()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.calls("qs"), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
