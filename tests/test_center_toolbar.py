#!/usr/bin/env python3
"""Exercise center toolbar clicks, popup handoffs and keyboard entry in real Qt.

Private session/system D-Bus and a synthetic Hyprland adapter keep production
windows, notifications, clipboard and media untouched.
"""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

if os.environ.get("QS_CENTER_TOOLBAR_PRIVATE_BUS") != "1":
    with tempfile.TemporaryDirectory(prefix="quickshell-center-toolbar-bus-") as directory:
        bus_config = Path(directory) / "bus.conf"
        bus_config.write_text('''<busconfig><type>session</type><listen>unix:tmpdir=/tmp</listen>
<policy context="default"><allow send_destination="*"/><allow receive_sender="*"/>
<allow own="*"/></policy></busconfig>''')
        raise SystemExit(subprocess.call(["dbus-run-session", "--config-file", str(bus_config),
                                          "--", sys.executable, __file__],
                                         env=dict(os.environ, QS_CENTER_TOOLBAR_PRIVATE_BUS="1")))

root = Path(__file__).resolve().parents[1]
work = Path(tempfile.mkdtemp(prefix="quickshell-center-toolbar-"))
config = work / "shell"
shutil.copytree(root, config, ignore=shutil.ignore_patterns("inspirations", "__pycache__"))
shutil.copy2(config / "tests/fixtures/center-toolbar.qml", config / "shell.qml")
(config / "services/HyprlandService.qml").write_text('''pragma Singleton
import Quickshell
Singleton {
    readonly property var fixtureWindow: ({address: "test", title: "Okno testowe"})
    function screenName(screen) { return "center-test"; }
    function activeToplevelFor(screen) { return fixtureWindow; }
    function activeWorkspace(screen) { return {id: 1}; }
    function contextApplicationId(window) { return ""; }
    function toplevelClass(window) { return "kitty"; }
    function isTerminal(window) { return true; }
    function isBrowser(window) { return false; }
    function displayTitleFor(screen) { return "/work/app"; }
    function terminalHostFor(screen) { return "test-host"; }
    function terminalCommandFor(screen) { return "fish"; }
}
''')
runtime = work / "runtime"
runtime.mkdir(mode=0o700)
env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_QPA_PLATFORMTHEME="", NO_AT_BRIDGE="1",
           WAYLAND_DISPLAY="", HYPRLAND_INSTANCE_SIGNATURE="",
           DBUS_SYSTEM_BUS_ADDRESS=os.environ["DBUS_SESSION_BUS_ADDRESS"],
           XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(work / "config"),
           XDG_STATE_HOME=str(work / "state"), XDG_CACHE_HOME=str(work / "cache"))

with (work / "shell.log").open("w") as log:
    proc = subprocess.Popen(["qs", "-p", str(config), "--no-color"], env=env, stdout=log, stderr=log)

    def ipc(function, *arguments):
        return subprocess.run(["qs", "ipc", "--pid", str(proc.pid), "call", "centertoolbartest",
                               function, *arguments], env=env, text=True, capture_output=True, timeout=15)

    try:
        deadline = time.monotonic() + 10
        while ipc("ready").stdout.strip() != "true":
            assert proc.poll() is None and time.monotonic() < deadline, f"Startup failed: {work}"
            time.sleep(.05)
        cycles = int(os.environ.get("QS_CENTER_TOOLBAR_TEST_CYCLES", "20"))
        geometry = []
        for cycle in range(cycles):
            result = ipc("run", "true" if cycle % 5 == 4 else "false")
            assert result.returncode == 0, (result.stdout, result.stderr, work)
            checks = json.loads(result.stdout)
            assert checks["passed"], {"cycle": cycle + 1, "logs": str(work), **checks}
            geometry.append(checks["geometry"])
        checks = json.loads(ipc("fallback").stdout)
        assert checks["passed"], {"logs": str(work), **checks}
        errors = re.findall(r"^.*(?:WARN scene|TypeError:|ReferenceError:|Binding loop).*$",
                            (work / "shell.log").read_text(), re.MULTILINE)
        assert not errors, {"qml_errors": errors, "logs": str(work)}
        (work / "result.json").write_text(json.dumps({"cycles": cycles, "geometry": geometry}, indent=2))
        print(f"PASS: {cycles} cycles; context-only idle, click reveal, inert hover, icon/panel handoffs,")
        print("stable 430 px panel frames, label fit, keyboard/IPC entry, reduced motion and fallback.")
        print(f"Logs: {work}")
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=3)
