#!/usr/bin/env python3
"""Exercise wallpaper ordering, image loading and crossfade with real Qt objects."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

if os.environ.get("QS_WALLPAPER_PRIVATE_BUS") != "1":
    raise SystemExit(subprocess.call(["dbus-run-session", "--", sys.executable, __file__],
                                    env=dict(os.environ, QS_WALLPAPER_PRIVATE_BUS="1")))

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="quickshell-wallpaper-") as tmp:
    work = Path(tmp)
    config = work / "shell"
    shutil.copytree(root, config, ignore=shutil.ignore_patterns("inspirations", "__pycache__"))
    shutil.copy2(root / "tests/fixtures/wallpaper.qml", config / "shell.qml")
    runtime = work / "runtime"
    runtime.mkdir(mode=0o700)
    env = dict(os.environ, QT_QPA_PLATFORM="offscreen", WAYLAND_DISPLAY="",
               HYPRLAND_INSTANCE_SIGNATURE="", XDG_RUNTIME_DIR=str(runtime),
               XDG_CONFIG_HOME=str(work / "config"), XDG_STATE_HOME=str(work / "state"),
               XDG_CACHE_HOME=str(work / "cache"))
    import struct, zlib
    backgrounds = work / "config/hypr/backgrounds"
    (backgrounds / "empty").mkdir(parents=True)
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    for name, rgb in [("a #one.PNG", (255, 0, 0)), ("b-two.png", (0, 255, 0)), ("c-three.png", (0, 0, 255))]:
        png = bytes.fromhex("89504e470d0a1a0a") + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
        png += chunk(b"IDAT", zlib.compress(bytes([0, *rgb]))) + chunk(b"IEND", b"")
        (backgrounds / name).write_bytes(png)
    (backgrounds / "z-broken.jpg").write_text("invalid image")
    (backgrounds / "ignore.txt").write_text("not a wallpaper")
    with (work / "shell.log").open("w+") as log:
        proc = subprocess.Popen(["qs", "-p", str(config), "--no-color"], env=env,
                                stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 10
            while True:
                result = subprocess.run(["qs", "ipc", "--pid", str(proc.pid), "call",
                                         "wallpapertest", "run"], env=env,
                                        text=True, capture_output=True, timeout=90)
                if result.returncode == 0 and result.stdout.strip():
                    break
                if proc.poll() is not None or time.monotonic() > deadline:
                    log.seek(0)
                    raise AssertionError(log.read() + result.stderr)
                time.sleep(.05)
            checks = json.loads(result.stdout)
            assert checks and all(check["passed"] for check in checks), checks
            def ipc(target, action):
                result = subprocess.run(["qs", "ipc", "--pid", str(proc.pid), "call", target, action],
                                        env=env, text=True, capture_output=True, timeout=10, check=True)
                return result.stdout.strip()
            initial = ipc("wallpapertest", "startTimer")
            deadline = time.monotonic() + 66
            while time.monotonic() < deadline:
                time.sleep(1)
                state = json.loads(ipc("wallpaper", "status"))
                if state["current"] != initial:
                    break
            else:
                raise AssertionError("Timer did not advance: " + repr(state))
            print("PASS test_timer (real one-minute interval)")
            log.seek(0)
            logs = log.read()
            unexpected = [line for line in logs.splitlines() if ("WARN" in line or "ERROR" in line)
                          and not any(allowed in line for allowed in ("z-broken", "offscreen", "QDir::"))]
            assert not unexpected, unexpected
            for check in checks:
                print("PASS", check["name"])
        finally:
            proc.terminate()
            proc.wait(timeout=5)
