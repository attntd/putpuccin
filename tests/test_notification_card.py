#!/usr/bin/env python3
"""Real Qt mouse/keyboard interaction tests on an isolated offscreen shell."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

if os.environ.get("QS_CARD_PRIVATE_BUS") != "1":
    with tempfile.TemporaryDirectory(prefix="quickshell-notification-bus-") as directory:
        bus_config = Path(directory) / "bus.conf"
        bus_config.write_text('<busconfig><type>session</type><listen>unix:tmpdir=/tmp</listen>'
            '<policy context="default"><allow send_destination="*"/><allow receive_sender="*"/>'
            '<allow own="*"/></policy></busconfig>')
        raise SystemExit(subprocess.call(["dbus-run-session", "--config-file", str(bus_config),
            "--", sys.executable, __file__], env=dict(os.environ, QS_CARD_PRIVATE_BUS="1")))

root = Path(__file__).resolve().parents[1]
work = Path(tempfile.mkdtemp(prefix="quickshell-card-test-"))
config = work / "shell"
shutil.copytree(root, config)
shutil.copy2(config / "tests/fixtures/notification-card.qml", config / "shell.qml")
runtime = work / "runtime"
runtime.mkdir(mode=0o700)
env = dict(os.environ, DBUS_SYSTEM_BUS_ADDRESS=os.environ["DBUS_SESSION_BUS_ADDRESS"], QT_QPA_PLATFORM="offscreen", QT_QPA_PLATFORMTHEME="", NO_AT_BRIDGE="1", WAYLAND_DISPLAY="", HYPRLAND_INSTANCE_SIGNATURE="",
           XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(work / "config"),
           XDG_STATE_HOME=str(work / "state"), XDG_CACHE_HOME=str(work / "cache"))
with (work / "shell.log").open("w") as log:
    proc = subprocess.Popen(["qs", "-p", str(config), "--no-color"], env=env, stdout=log, stderr=subprocess.STDOUT)
    command = ["qs", "ipc", "--pid", str(proc.pid), "call", "cardtest", "run"]
    try:
        deadline = time.monotonic() + 5
        while True:
            result = subprocess.run(command, env=env, text=True, capture_output=True, timeout=15)
            if result.returncode == 0 and result.stdout.strip():
                break
            if proc.poll() is not None or time.monotonic() > deadline:
                raise AssertionError(f"Test shell failed: {work}")
            time.sleep(.05)
        for cycle in range(int(os.environ.get("QS_CARD_TEST_CYCLES", "20"))):
            if cycle:
                result = subprocess.run(command, env=env, text=True, capture_output=True, check=True, timeout=15)
            checks = json.loads(result.stdout)
            assert checks and all(c["passed"] for c in checks), checks
        print("PASS", os.environ.get("QS_CARD_TEST_CYCLES", "20"), "cycles: whole-card actions, expand/collapse, discard isolation, keyboard, secondary action, compact center with click expansion and inert hover, compact toast with animated controls, clear confirmation fade, long text animation and reversal")
        print(f"Logs: {work}")
    finally:
        proc.terminate()
        proc.wait(timeout=15)
