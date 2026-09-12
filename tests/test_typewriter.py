#!/usr/bin/env python3
"""Exercise real QML timers with rapidly changing terminal window titles."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

if os.environ.get("QS_TYPEWRITER_PRIVATE_BUS") != "1":
    raise SystemExit(subprocess.call(["dbus-run-session", "--", sys.executable, __file__],
                                    env=dict(os.environ, QS_TYPEWRITER_PRIVATE_BUS="1")))

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="quickshell-typewriter-") as tmp:
    work = Path(tmp)
    config = work / "shell"
    shutil.copytree(root, config, ignore=shutil.ignore_patterns("inspirations", "__pycache__"))
    shutil.copy2(root / "tests/fixtures/typewriter.qml", config / "shell.qml")
    runtime = work / "runtime"
    runtime.mkdir(mode=0o700)
    env = dict(os.environ, QT_QPA_PLATFORM="offscreen", WAYLAND_DISPLAY="",
               HYPRLAND_INSTANCE_SIGNATURE="", XDG_RUNTIME_DIR=str(runtime),
               XDG_CONFIG_HOME=str(work / "config"), XDG_STATE_HOME=str(work / "state"),
               XDG_CACHE_HOME=str(work / "cache"))
    with (work / "shell.log").open("w+") as log:
        proc = subprocess.Popen(["qs", "-p", str(config), "--no-color"], env=env,
                                stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 10
            while True:
                result = subprocess.run(["qs", "ipc", "--pid", str(proc.pid), "call",
                                         "typewritertest", "run"], env=env,
                                        text=True, capture_output=True, timeout=15)
                if result.returncode == 0 and result.stdout.strip():
                    break
                if proc.poll() is not None or time.monotonic() > deadline:
                    log.seek(0)
                    raise AssertionError(log.read() + result.stderr)
                time.sleep(.05)
            checks = json.loads(result.stdout)
            assert checks and all(check["passed"] for check in checks), checks
            for check in checks:
                print("PASS", check["name"])
        finally:
            proc.terminate()
            proc.wait(timeout=5)
