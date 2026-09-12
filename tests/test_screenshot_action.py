#!/usr/bin/env python3
"""Synthetic PNGs and stub commands; never capture, notify or change the live clipboard."""

import base64
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import select
import stat
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
import zlib


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts/screenshot-action"
loader = importlib.machinery.SourceFileLoader("screenshot_action", str(HELPER))
spec = importlib.util.spec_from_loader(loader.name, loader)
action = importlib.util.module_from_spec(spec)
loader.exec_module(action)


def png(width=16, height=12):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    rows = b"".join(b"\0" + b"".join(bytes((x * 9, y * 13, (x + y) * 4, 255)) for x in range(width)) for y in range(height))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")


def wait_for(predicate, timeout=4):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.02)
    raise AssertionError("Timed out waiting for the isolated fixture")


class ScreenshotActionTests(unittest.TestCase):
    def setUp(self):
        self.previous_umask = os.umask(0o077)
        os.umask(self.previous_umask)
        self.tmp = tempfile.TemporaryDirectory(prefix="quickshell-screenshot-io-test-")
        self.work = Path(self.tmp.name)
        self.bin = self.work / "bin"
        self.runtime = self.work / "runtime"
        self.home = self.work / "home"
        self.config = self.work / "config"
        for directory in (self.bin, self.runtime, self.home, self.config):
            directory.mkdir(mode=0o700)
        self.env = dict(os.environ, PATH=str(self.bin), HOME=str(self.home),
                        XDG_RUNTIME_DIR=str(self.runtime), XDG_CONFIG_HOME=str(self.config),
                        DBUS_SESSION_BUS_ADDRESS="unix:path=/no-screenshot-test-bus",
                        TEST_SCREENSHOT_WORK=str(self.work))
        self.fixture = png()
        self.children = []

    def tearDown(self):
        # Release every editor, including after an assertion failure.
        (self.work / "editor-release").write_text("done")
        for path in (self.runtime / "quickshell-de-screenshots").glob("capture-*"):
            if (path / ".session").exists():
                with mock.patch.dict(os.environ, self.env, clear=True):
                    try:
                        action.cleanup(str(path))
                    except action.ActionError:
                        pass
        for child in self.children:
            if child.poll() is None:
                child.terminate()
                child.wait(timeout=2)
        self.tmp.cleanup()
        os.umask(self.previous_umask)

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!" + sys.executable + "\nimport json,os,sys,time\nfrom pathlib import Path\nw=Path(os.environ['TEST_SCREENSHOT_WORK'])\n" + body)
        path.chmod(0o700)
        return path

    def call(self, *args, expected=True, env=None, timeout=8):
        result = subprocess.run([sys.executable, str(HELPER), *map(str, args)],
                                cwd=self.work, env=env or self.env, capture_output=True, text=True, timeout=timeout)
        self.assertEqual(result.stderr, "", result.stderr)
        self.assertEqual(result.returncode, 0 if expected else 1, result.stdout)
        value = json.loads(result.stdout)
        self.assertEqual(value["ok"], expected, value)
        return value

    def session(self, source="result.png", owner=""):
        reply = self.call("prepare", *([owner] if owner else []))
        path = Path(reply["directory"])
        if source:
            (path / source).write_bytes(self.fixture)
        return path

    def copy_stub(self, status=0):
        self.stub("wl-copy", "(w/'clipboard.png').write_bytes(sys.stdin.buffer.read())\n(w/'copy-argv.json').write_text(json.dumps(sys.argv[1:]))\nsys.exit(" + str(status) + ")\n")

    def test_prepare_permissions_capabilities_and_repeated_cleanup(self):
        reply = self.call("prepare", str(os.getpid()))
        directory = Path(reply["directory"])
        self.assertFalse(reply["editorAvailable"])
        self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(directory.parent.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((directory / ".session").stat().st_mode), 0o600)
        self.assertEqual(json.loads((directory / ".session").read_text())["ownerPid"], os.getpid())
        self.assertTrue(self.call("cleanup", directory)["removed"])
        self.assertFalse(self.call("cleanup", directory)["removed"])
        self.stub("satty", "sys.exit(0)\n")
        self.assertTrue(self.call("prepare")["editorAvailable"])

    def test_reap_dead_owners_but_preserve_live_and_unknown_sessions(self):
        process = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        self.children.append(process)
        orphan = self.session(owner=str(process.pid))
        live = self.session(owner=str(os.getpid()))
        unknown = self.session()
        process.terminate()
        process.wait(timeout=2)
        self.call("prepare", str(os.getpid()))
        self.assertFalse(orphan.exists())
        self.assertTrue(live.exists())
        self.assertTrue(unknown.exists())

    def test_cleanup_rejects_arbitrary_traversal_symlink_and_unmarked_directories(self):
        session = self.session()
        outside = self.work / "unrelated"
        outside.mkdir()
        protected = outside / "keep"
        protected.write_text("untouched")
        self.assertEqual(self.call("cleanup", outside, expected=False)["code"], "unsafe_session")
        traversal = str(session.parent) + "/../quickshell-de-screenshots/" + session.name
        self.assertEqual(self.call("cleanup", traversal, expected=False)["code"], "unsafe_session")
        linked = session.parent / ("capture-" + "f" * 32)
        linked.symlink_to(outside, target_is_directory=True)
        self.assertEqual(self.call("cleanup", linked, expected=False)["code"], "unsafe_session")
        unmarked = session.parent / ("capture-" + "a" * 32)
        unmarked.mkdir(mode=0o700)
        self.assertEqual(self.call("cleanup", unmarked, expected=False)["code"], "unsafe_session")
        (session / "linked.png").symlink_to(protected)
        self.assertEqual(self.call("cleanup", session, expected=False)["code"], "unsafe_session")
        self.assertEqual(protected.read_text(), "untouched")
        self.assertEqual((session / "result.png").read_bytes(), self.fixture)
        (session / "linked.png").unlink()
        self.assertTrue(self.call("cleanup", session)["removed"])

    def test_rejects_symlink_runtime_and_insecure_existing_base(self):
        linked = self.work / "linked-runtime"
        linked.symlink_to(self.runtime, target_is_directory=True)
        self.call("prepare", expected=False, env=dict(self.env, XDG_RUNTIME_DIR=str(linked)))
        base = self.runtime / "quickshell-de-screenshots"
        base.mkdir(mode=0o755)
        base.chmod(0o755)
        self.assertEqual(self.call("prepare", expected=False)["code"], "unsafe_session")

    def test_copy_png_stdin_mime_and_no_automatic_paste(self):
        self.copy_stub()
        session = self.session()
        reply = self.call("finish", "copy", session, "")
        self.assertEqual(reply["path"], "")
        self.assertEqual((self.work / "clipboard.png").read_bytes(), self.fixture)
        self.assertEqual(json.loads((self.work / "copy-argv.json").read_text()), ["--type", "image/png"])
        self.assertEqual((session / "result.png").read_bytes(), self.fixture)
        self.assertEqual(stat.S_IMODE((session / "result.png").stat().st_mode), 0o600)

    def test_copy_failure_missing_command_and_timeout_preserve_image(self):
        session = self.session()
        self.assertEqual(self.call("finish", "copy", session, "", expected=False)["code"], "clipboard_missing")
        self.copy_stub(status=7)
        self.assertEqual(self.call("finish", "copy", session, "", expected=False)["code"], "clipboard_failed")
        self.stub("wl-copy", "time.sleep(30)\n")
        with mock.patch.dict(os.environ, self.env, clear=True), mock.patch.object(action, "COPY_TIMEOUT", 0.05):
            before = time.monotonic()
            with self.assertRaises(action.ActionError) as error:
                action.finish("copy", str(session), "", action.DEFAULT_NOTIFICATION)
            self.assertEqual(error.exception.code, "clipboard_timeout")
            self.assertLess(time.monotonic() - before, 2)
        self.assertEqual((session / "result.png").read_bytes(), self.fixture)

    def test_invalid_png_hardlink_symlink_and_fifo_fail_without_blocking(self):
        self.copy_stub()
        session = self.session()
        capture = session / "result.png"
        capture.write_bytes(b"not a PNG")
        self.assertEqual(self.call("finish", "copy", session, "", expected=False)["code"], "invalid_image")
        capture.unlink()
        outside = self.work / "external.png"
        outside.write_bytes(self.fixture)
        for kind in ("symlink", "hardlink", "fifo"):
            if kind == "symlink":
                capture.symlink_to(outside)
            elif kind == "hardlink":
                os.link(outside, capture)
            else:
                os.mkfifo(capture)
            self.assertEqual(self.call("finish", "copy", session, "", expected=False, timeout=2)["code"], "invalid_image")
            capture.unlink()
        self.assertFalse((self.work / "clipboard.png").exists())
        self.assertEqual(outside.read_bytes(), self.fixture)

    def test_save_uses_xdg_pictures_and_never_overwrites(self):
        (self.config / "user-dirs.dirs").write_text('XDG_PICTURES_DIR="$HOME/Obrazy rodzinne"\n')
        session = self.session()
        first = Path(self.call("finish", "save", session, "")["path"])
        second = Path(self.call("finish", "save", session, "")["path"])
        self.assertEqual(first.parent, self.home / "Obrazy rodzinne/Screenshots")
        self.assertNotEqual(first, second)
        self.assertEqual(first.read_bytes(), self.fixture)
        self.assertEqual(second.read_bytes(), self.fixture)
        self.assertEqual(stat.S_IMODE(first.stat().st_mode), 0o600)
        # Force an actual O_EXCL collision and ensure the existing file survives.
        collision = first.parent / "Screenshot-constant-aaaaaaaaaaaa.png"
        collision.write_bytes(b"existing")
        with mock.patch.dict(os.environ, self.env, clear=True), mock.patch.object(action.time, "strftime", return_value="Screenshot-constant"), mock.patch.object(action.uuid, "uuid4", side_effect=[mock.Mock(hex="a" * 32), mock.Mock(hex="b" * 32)]), mock.patch.object(action, "notify_saved"):
            saved = action.finish("save", str(session), str(first.parent), action.DEFAULT_NOTIFICATION)
        self.assertEqual(collision.read_bytes(), b"existing")
        self.assertTrue(saved["path"].endswith("bbbbbbbbbbbb.png"))

    def test_save_rejects_symlink_and_traversal_and_cleans_partial_failure(self):
        session = self.session()
        outside = self.work / "outside"
        outside.mkdir()
        linked = self.work / "save-link"
        linked.symlink_to(outside, target_is_directory=True)
        for destination in (str(linked), str(self.work) + "/outside/../escape", "relative/path"):
            self.assertEqual(self.call("finish", "save", session, destination, expected=False)["code"], "invalid_destination")
        output = self.work / "saved"
        with mock.patch.dict(os.environ, self.env, clear=True), mock.patch.object(action.shutil, "copyfileobj", side_effect=OSError("synthetic disk failure")):
            with self.assertRaises(action.ActionError) as error:
                action.finish("save", str(session), str(output), action.DEFAULT_NOTIFICATION)
            self.assertEqual(error.exception.code, "save_failed")
        self.assertEqual(list(output.iterdir()), [])
        self.assertEqual((session / "result.png").read_bytes(), self.fixture)

    def test_save_deadline_removes_partial_file_and_keeps_original(self):
        session = self.session()
        output = self.work / "saved"

        def stalled_copy(source, destination, *args):
            destination.write(b"synthetic partial write")
            destination.flush()
            time.sleep(1)

        reply = io.StringIO()
        with mock.patch.dict(os.environ, self.env, clear=True), mock.patch.object(action, "IO_TIMEOUT", 0.05), mock.patch.object(action.shutil, "copyfileobj", side_effect=stalled_copy), mock.patch.object(action.sys, "stdout", reply):
            code = action.main(["finish", "save", str(session), str(output)])
        self.assertEqual(code, 1)
        self.assertEqual(json.loads(reply.getvalue())["code"], "save_timeout")
        self.assertEqual(list(output.iterdir()), [])
        self.assertEqual((session / "result.png").read_bytes(), self.fixture)

    def test_prepare_deadline_removes_incomplete_session(self):
        prior = self.session()

        def stalled_marker(value, stream):
            stream.write("{")
            stream.flush()
            time.sleep(1)

        reply = io.StringIO()
        with mock.patch.dict(os.environ, self.env, clear=True), mock.patch.object(action, "IO_TIMEOUT", 0.05), mock.patch.object(action.json, "dump", side_effect=stalled_marker), mock.patch.object(action.sys, "stdout", reply):
            code = action.main(["prepare"])
        self.assertEqual(code, 1)
        self.assertEqual(json.loads(reply.getvalue())["code"], "prepare_timeout")
        self.assertEqual(list((self.runtime / "quickshell-de-screenshots").iterdir()), [prior])

    def test_cleanup_waits_for_inflight_crop_and_survives_caller_termination(self):
        self.stub("magick", "(w/'crop-pid').write_text(str(os.getpid()))\ntime.sleep(30)\n")
        session = self.session(source="screen-0.png")
        crop = subprocess.Popen([sys.executable, str(HELPER), "crop", str(session), "screen-0.png", "0", "0", "5", "4"], env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.children.append(crop)
        wait_for(lambda: (self.work / "crop-pid").exists())
        child_pid = int((self.work / "crop-pid").read_text())
        cleanup = subprocess.Popen([sys.executable, str(HELPER), "cleanup", str(session)], env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.children.append(cleanup)
        self.assertEqual(select.select([cleanup.stdout], [], [], .1)[0], [])
        # Simulate QML destroying its Process during reload. The standalone
        # cleanup process must finish even though no service callback survives.
        crop.terminate()
        result, errors = crop.communicate(timeout=3)
        self.assertEqual(errors, "")
        self.assertEqual(json.loads(result)["code"], "cancelled")
        result, errors = cleanup.communicate(timeout=3)
        self.assertEqual(errors, "")
        self.assertTrue(json.loads(result)["removed"])
        self.assertFalse(session.exists())
        with self.assertRaises(ProcessLookupError):
            os.kill(child_pid, 0)

    def test_cleanup_wait_has_deadline_and_leaves_busy_capture_intact(self):
        session = self.session()
        with mock.patch.dict(os.environ, self.env, clear=True), mock.patch.object(action, "CLEANUP_TIMEOUT", 0.05):
            with action.Session(str(session)) as owner:
                owner.lock()
                with self.assertRaises(action.ActionError) as error:
                    action.cleanup(str(session))
                self.assertEqual(error.exception.code, "cleanup_timeout")
                self.assertEqual((session / "result.png").read_bytes(), self.fixture)
            self.assertTrue(action.cleanup(str(session))["removed"])

    def test_arguments_are_never_shell_commands(self):
        self.stub("notify-send", "(w/'notify-argv.json').write_text(json.dumps(sys.argv[1:]))\n")
        session = self.session()
        destination = self.work / "saved;$(touch injected)"
        self.call("finish", "save", session, destination, "$(touch notified)", "literal body", "Open")
        wait_for(lambda: (self.work / "notify-argv.json").exists())
        self.assertFalse((self.work / "injected").exists())
        self.assertFalse((self.work / "notified").exists())
        self.assertTrue(destination.is_dir())
        self.assertEqual(self.call("finish", "copy;touch", session, "", expected=False)["code"], "bad_arguments")
        self.assertEqual(self.call("crop", session, "../result.png", "0", "0", "1", "1", expected=False)["code"], "invalid_crop")

    def test_transient_notification_has_open_action_and_no_image(self):
        self.stub("notify-send", "(w/'notify-argv.json').write_text(json.dumps(sys.argv[1:]))\nprint('open')\n")
        self.stub("xdg-open", "(w/'open-argv.json').write_text(json.dumps(sys.argv[1:]))\n")
        session = self.session()
        saved = self.call("finish", "save", session, str(self.work / "saved"), "Saved", "Click to open", "Open")
        wait_for(lambda: (self.work / "open-argv.json").exists())
        argv = json.loads((self.work / "notify-argv.json").read_text())
        self.assertIn("--hint=boolean:transient:true", argv)
        self.assertIn("--action=open=Open", argv)
        self.assertIn("--expire-time=8000", argv)
        self.assertNotIn(saved["path"], argv)
        self.assertNotIn(str(session), " ".join(argv))
        self.assertEqual(json.loads((self.work / "open-argv.json").read_text()), [Path(saved["path"]).as_uri()])

    def test_notification_timeout_is_bounded_and_does_not_open(self):
        self.stub("notify-send", "time.sleep(30)\n")
        self.stub("xdg-open", "(w/'opened').write_text('unexpected')\n")
        with mock.patch.dict(os.environ, self.env, clear=True), mock.patch.object(action, "NOTIFICATION_TIMEOUT", 0.05):
            before = time.monotonic()
            action.notification_worker(str(self.work / "saved.png"), action.DEFAULT_NOTIFICATION)
            self.assertLess(time.monotonic() - before, 2)
        self.assertFalse((self.work / "opened").exists())

    def test_missing_editor_and_failed_launch_preserve_capture(self):
        session = self.session()
        self.assertEqual(self.call("finish", "edit", session, "", expected=False)["code"], "editor_missing")
        self.stub("satty", "sys.exit(9)\n")
        self.assertEqual(self.call("finish", "edit", session, "", expected=False)["code"], "editor_failed")
        self.assertEqual((session / "result.png").read_bytes(), self.fixture)
        self.assertEqual(list((self.home / "Pictures/Screenshots").glob("*.png")), [])

    def test_editor_start_timeout_stops_worker_and_preserves_retry(self):
        self.stub("satty", "sys.exit(0)\n")
        session = self.session()
        worker = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"],
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
        self.children.append(worker)
        with mock.patch.dict(os.environ, self.env, clear=True), mock.patch.object(action, "EDITOR_START_TIMEOUT", 0.05), mock.patch.object(action, "detach", return_value=worker):
            with self.assertRaises(action.ActionError) as error:
                action.start_editor(str(session), "", action.DEFAULT_NOTIFICATION)
            self.assertEqual(error.exception.code, "editor_timeout")
        self.assertIsNotNone(worker.poll())
        self.assertEqual((session / "result.png").read_bytes(), self.fixture)
        self.copy_stub()
        self.call("finish", "copy", session, "")

    def test_editor_survives_caller_exit_defers_cleanup_then_removes_temp(self):
        self.stub("satty", "(w/'editor-argv.json').write_text(json.dumps(sys.argv[1:]))\nwhile not (w/'editor-release').exists(): time.sleep(.02)\n")
        session = self.session()
        reply = self.call("finish", "edit", session, "")
        self.assertTrue(reply["editorStarted"])
        self.assertEqual(reply["path"], "")
        self.assertTrue(self.call("cleanup", session)["deferred"])
        self.assertTrue((session / "result.png").exists())
        argv = json.loads((self.work / "editor-argv.json").read_text())
        self.assertEqual(argv[argv.index("--filename") + 1], str(session / "result.png"))
        self.assertIn("--disable-notifications", argv)
        self.assertEqual(argv[argv.index("--copy-command") + 1], "wl-copy --type image/png")
        (self.work / "editor-release").write_text("done")
        wait_for(lambda: not session.exists())
        self.assertEqual(list((self.home / "Pictures/Screenshots").glob("*.png")), [])

    def test_editor_handoff_survives_closed_acknowledgement_pipe(self):
        self.stub("satty", "(w/'editor-started').write_text('yes')\nwhile not (w/'editor-release').exists(): time.sleep(.02)\n")
        session = self.session()
        worker = subprocess.Popen([sys.executable, str(HELPER), "_edit", str(session), "", *action.DEFAULT_NOTIFICATION], env=self.env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.children.append(worker)
        worker.stdout.close()
        wait_for(lambda: (session / ".editing").exists())
        self.assertIsNone(worker.poll())
        self.assertTrue(self.call("cleanup", session)["deferred"])
        (self.work / "editor-release").write_text("done")
        self.assertEqual(worker.wait(timeout=3), 0)
        self.assertFalse(session.exists())

    def test_editor_save_is_private_and_kept_after_temp_cleanup(self):
        payload = base64.b64encode(self.fixture).decode()
        self.stub("satty", "import base64\npath=Path(sys.argv[sys.argv.index('--output-filename')+1])\npath.write_bytes(base64.b64decode(" + repr(payload) + "))\ntime.sleep(.2)\n")
        session = self.session()
        self.call("finish", "edit", session, str(self.work / "edited"))
        wait_for(lambda: not session.exists())
        paths = list((self.work / "edited").glob("*.png"))
        self.assertEqual(len(paths), 1)
        self.assertEqual(paths[0].read_bytes(), self.fixture)
        self.assertEqual(stat.S_IMODE(paths[0].stat().st_mode), 0o600)

    def test_crop_real_pixels_dimensions_and_original_preserved(self):
        magick = shutil.which("magick")
        if not magick:
            self.skipTest("ImageMagick unavailable")
        (self.bin / "magick").symlink_to(magick)
        session = self.session(source="screen-0.png")
        result = self.call("crop", session, "screen-0.png", "3", "2", "5", "4")
        self.assertEqual((result["width"], result["height"]), (5, 4))
        image = session / "result.png"
        pixels = subprocess.check_output([magick, str(image), "-depth", "8", "rgba:-"], timeout=5)
        expected = b"".join(bytes((x * 9, y * 13, (x + y) * 4, 255)) for y in range(2, 6) for x in range(3, 8))
        self.assertEqual(pixels, expected)
        self.assertEqual((session / "screen-0.png").read_bytes(), self.fixture)
        self.assertEqual(stat.S_IMODE(image.stat().st_mode), 0o600)

    def test_crop_bounds_failure_timeout_and_old_result_are_preserved(self):
        session = self.session(source="screen-0.png")
        previous = session / "result.png"
        previous.write_bytes(self.fixture)
        self.assertEqual(self.call("crop", session, "screen-0.png", "0", "0", "1", "1", expected=False)["code"], "crop_unavailable")
        self.stub("magick", "sys.exit(3)\n")
        for coordinates in (("0", "0", "0", "1"), ("-1", "0", "1", "1"), ("15", "0", "2", "1"), ("0; touch injected", "0", "1", "1"), ("0", "0", "1.5", "1")):
            self.assertEqual(self.call("crop", session, "screen-0.png", *coordinates, expected=False)["code"], "invalid_crop")
        self.assertEqual(self.call("crop", session, "screen-0.png", "0", "0", "1", "1", expected=False)["code"], "crop_failed")
        self.stub("magick", "time.sleep(30)\n")
        with mock.patch.dict(os.environ, self.env, clear=True), mock.patch.object(action, "CROP_TIMEOUT", 0.05):
            with self.assertRaises(action.ActionError) as error:
                action.crop(str(session), "screen-0.png", ["0", "0", "1", "1"])
            self.assertEqual(error.exception.code, "crop_timeout")
        self.assertEqual(previous.read_bytes(), self.fixture)
        self.assertEqual(list(session.glob(".crop-*")), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
