#!/usr/bin/env python3
"""Missing wallpaper during sourceSize reload: retain front, then recover."""
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import zlib

if os.environ.get("QS_WALLPAPER_FAULT_BUS") != "1":
    raise SystemExit(subprocess.call(["dbus-run-session", "--", sys.executable, __file__],
                                    env=dict(os.environ, QS_WALLPAPER_FAULT_BUS="1")))

root = Path(__file__).resolve().parents[1]
work = Path(tempfile.mkdtemp(prefix="quickshell-wallpaper-fault-"))
config = work / "shell"
shutil.copytree(root, config, ignore=shutil.ignore_patterns("inspirations", "__pycache__"))
shutil.copy2(root / "tests/fixtures/wallpaper-fault.qml", config / "shell.qml")
if os.environ.get("QS_WALLPAPER_VIEW_BASELINE"):
    shutil.copy2(os.environ["QS_WALLPAPER_VIEW_BASELINE"],
                 config / "modules/wallpaper/WallpaperView.qml")


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


for name, rgb in [("a", (255, 0, 0)), ("b", (0, 255, 0)), ("c", (0, 0, 255))]:
    (work / (name + ".png")).write_bytes(bytes.fromhex("89504e470d0a1a0a")
        + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes([0, *rgb]))) + chunk(b"IEND", b""))

runtime = work / "runtime"
runtime.mkdir(mode=0o700)
env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_QPA_PLATFORMTHEME="",
           WAYLAND_DISPLAY="", HYPRLAND_INSTANCE_SIGNATURE="", XDG_RUNTIME_DIR=str(runtime),
           XDG_CONFIG_HOME=str(work / "config"), XDG_STATE_HOME=str(work / "state"),
           XDG_CACHE_HOME=str(work / "cache"),
           QS_WALLPAPER_FAULT_A=(work / "a.png").as_uri(),
           QS_WALLPAPER_FAULT_B=(work / "b.png").as_uri(),
           QS_WALLPAPER_FAULT_C=(work / "c.png").as_uri())

with (work / "shell.log").open("w") as log:
    proc = subprocess.Popen(["qs", "-p", str(config), "--no-color"], env=env,
                            stdout=log, stderr=log)
    try:
        def ipc(action):
            return subprocess.run(["qs", "ipc", "--pid", str(proc.pid), "call",
                                   "wallpaperfault", action], env=env, text=True,
                                  capture_output=True, timeout=6)

        deadline = time.monotonic() + 10
        while True:
            response = ipc("begin")
            if response.returncode == 0 and response.stdout.strip():
                break
            assert proc.poll() is None and time.monotonic() < deadline, str(work)
            time.sleep(.05)
        before = json.loads(response.stdout)
        assert before["transitioning"] and before["hasFront"] and before["hasIncoming"], before
        (work / "b.png").unlink()
        after = json.loads(ipc("resize").stdout)
        result = {"before": before, "after": after}
        (work / "result.json").write_text(json.dumps(result, indent=2))
        print(work, flush=True)
        assert after["failures"] == 1 and not after["transitioning"] and not after["hasIncoming"], after
        assert after["displayedSource"] == env["QS_WALLPAPER_FAULT_A"] and after["frontStatus"] == 1, after
        assert after["frontOpacity"] == 1, after
        recovered = json.loads(ipc("recover").stdout)
        result["recovered"] = recovered
        (work / "result.json").write_text(json.dumps(result, indent=2))
        assert recovered["displayedSource"] == env["QS_WALLPAPER_FAULT_C"], recovered
        assert not recovered["transitioning"] and not recovered["hasIncoming"] and recovered["frontStatus"] == 1, recovered
        logs = (work / "shell.log").read_text()
        assert not any(error in logs for error in ["TypeError", "ReferenceError", "Binding loop", "Cannot assign"]), logs
        print("PASS: missing incoming during fade + resize retains ready front; next image and late finish recover")
    finally:
        proc.terminate()
        proc.wait(timeout=5)
