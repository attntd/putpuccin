#!/usr/bin/env python3
"""Real Qt mouse/keyboard interaction tests on an isolated offscreen shell."""
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

if os.environ.get("QS_CENTER_PRIVATE_BUS") != "1":
    with tempfile.TemporaryDirectory(prefix="quickshell-notification-bus-") as directory:
        bus_config = Path(directory) / "bus.conf"
        bus_config.write_text('<busconfig><type>session</type><listen>unix:tmpdir=/tmp</listen>'
            '<policy context="default"><allow send_destination="*"/><allow receive_sender="*"/>'
            '<allow own="*"/></policy></busconfig>')
        raise SystemExit(subprocess.call(["dbus-run-session", "--config-file", str(bus_config),
            "--", sys.executable, __file__], env=dict(os.environ, QS_CENTER_PRIVATE_BUS="1")))

root = Path(__file__).resolve().parents[1]
work = Path(tempfile.mkdtemp(prefix="quickshell-center-test-"))
config = work / "shell"
shutil.copytree(root, config)
shutil.copy2(config / "tests/fixtures/notification-center.qml", config / "shell.qml")
# Fixture screens are plain objects rather than native QsScreenInfo instances.
hyprland = config / "services/HyprlandService.qml"
hyprland.write_text(hyprland.read_text().replace(
    'return screen ? Hyprland.monitorFor(screen) : null;', 'return null;'))
runtime = work / "runtime"
runtime.mkdir(mode=0o700)
env = dict(os.environ, DBUS_SYSTEM_BUS_ADDRESS=os.environ["DBUS_SESSION_BUS_ADDRESS"], QT_QPA_PLATFORM="offscreen", QT_QPA_PLATFORMTHEME="", NO_AT_BRIDGE="1", WAYLAND_DISPLAY="", HYPRLAND_INSTANCE_SIGNATURE="",
           QML_IMPORT_PATH=str(config / "integrations"),
           XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(work / "config"),
           XDG_STATE_HOME=str(work / "state"), XDG_CACHE_HOME=str(work / "cache"))
with (work / "shell.log").open("w") as log:
    proc = subprocess.Popen(["qs", "-p", str(config), "--no-color"], env=env, stdout=log, stderr=subprocess.STDOUT)
    command = ["qs", "ipc", "--pid", str(proc.pid), "call", "centertest", "run"]
    try:
        deadline = time.monotonic() + 5
        while True:
            result = subprocess.run(command, env=env, text=True, capture_output=True, timeout=15)
            if result.returncode == 0 and result.stdout.strip():
                break
            if proc.poll() is not None or time.monotonic() > deadline:
                raise AssertionError(f"Test shell failed: {work}")
            time.sleep(.05)
        for cycle in range(int(os.environ.get("QS_CENTER_TEST_CYCLES", "20"))):
            if cycle:
                result = subprocess.run(command, env=env, text=True, capture_output=True, check=True, timeout=15)
            try:
                checks = json.loads(result.stdout)
            except json.JSONDecodeError as error:
                raise AssertionError((result.stdout, result.stderr, str(work))) from error
            assert checks["passed"], {"cycle":cycle + 1, **checks}
        warnings = re.findall(r'^.*(?:WARN scene|TypeError:|ReferenceError:|Binding loop).*$',
            (work / "shell.log").read_text(), re.M)
        assert not warnings, (warnings, str(work))
        print("PASS", os.environ.get("QS_CENTER_TEST_CYCLES", "20"), "cycles: center click handoffs, inert hover, group gaps, rapid retargets, bottom geometry, keyboard, filtering, scrolling and screen margins")
        print(f"Logs: {work}")
    finally:
        proc.terminate()
        proc.wait(timeout=15)
