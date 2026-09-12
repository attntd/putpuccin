#!/usr/bin/env python3
"""Compare stationary toolbar pixels at intermediate expansion dimensions.

Runs actual Qt components on private D-Bus. QS_TOOLBAR_RENDER_BASELINE can
point to a previous BarIsland.qml to verify that the regression is detected.
QT_SCALE_FACTOR and QT_QUICK_BACKEND select scale and renderer. Set
QS_TOOLBAR_RENDER_PLATFORM=wayland for the native compositor/GPU check.
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

if os.environ.get("QS_TOOLBAR_RENDER_PRIVATE_BUS") != "1":
    with tempfile.TemporaryDirectory(prefix="quickshell-toolbar-render-bus-") as directory:
        bus = Path(directory) / "bus.conf"
        bus.write_text('''<busconfig><type>session</type><listen>unix:tmpdir=/tmp</listen>
<policy context="default"><allow send_destination="*"/><allow receive_sender="*"/>
<allow own="*"/></policy></busconfig>''')
        raise SystemExit(subprocess.call(["dbus-run-session", "--config-file", str(bus),
            "--", sys.executable, __file__],
            env=dict(os.environ, QS_TOOLBAR_RENDER_PRIVATE_BUS="1")))

root = Path(__file__).resolve().parents[1]
work = Path(tempfile.mkdtemp(prefix="quickshell-toolbar-render-"))
config = work / "shell"
for directory in ("core", "components", "modules", "popups", "services", "assets", "config", "integrations"):
    shutil.copytree(root / directory, config / directory, ignore=shutil.ignore_patterns("__pycache__"))
if os.environ.get("QS_TOOLBAR_RENDER_BASELINE"):
    shutil.copy2(os.environ["QS_TOOLBAR_RENDER_BASELINE"], config / "modules/statusbar/BarIsland.qml")
shutil.copy2(root / "tests/fixtures/toolbar-rendering.qml", config / "shell.qml")
(config / "services/HyprlandService.qml").write_text('''pragma Singleton
import Quickshell
Singleton {
    readonly property var fixtureWindow: ({address: "test", title: "Okno testowe"})
    function screenName(screen) { return "render-test"; }
    function activeToplevelFor(screen) { return fixtureWindow; }
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
    QML_IMPORT_PATH=str(config / "integrations"),
    XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(work / "config"),
    XDG_STATE_HOME=str(work / "state"), XDG_CACHE_HOME=str(work / "cache"))
if os.environ.get("QS_TOOLBAR_RENDER_PLATFORM") == "wayland":
    env["QT_QPA_PLATFORM"] = "wayland"
    env["WAYLAND_DISPLAY"] = str(Path(os.environ["XDG_RUNTIME_DIR"]) / os.environ["WAYLAND_DISPLAY"])

with (work / "shell.log").open("w") as log:
    proc = subprocess.Popen(["qs", "-p", str(config), "--no-color"], env=env, stdout=log, stderr=log)

    def ipc(method, *args):
        return subprocess.run(["qs", "ipc", "--pid", str(proc.pid), "call", "toolbarrendertest",
            method, *args], env=env, capture_output=True, text=True, timeout=30)

    def measure():
        time.sleep(.5)
        path = Path(f"/proc/{proc.pid}")
        def ticks():
            fields = (path / "stat").read_text().rsplit(")", 1)[1].split()
            return int(fields[11]) + int(fields[12])
        start = ticks()
        now = time.monotonic()
        time.sleep(.5)
        return {"cpuPercent": round((ticks() - start) / os.sysconf("SC_CLK_TCK")
            / (time.monotonic() - now) * 100, 2),
            "rssKiB": int(re.search(r"^VmRSS:\s+(\d+)",
                (path / "status").read_text(), re.MULTILINE).group(1))}

    try:
        deadline = time.monotonic() + 10
        while ipc("ready").stdout.strip() != "true":
            assert proc.poll() is None and time.monotonic() < deadline, str(work)
            time.sleep(.05)
        # Warm the renderer and release test-owned image buffers before measuring.
        ipc("run", "")
        ipc("collect")
        before = measure()
        cycles = int(os.environ.get("QS_TOOLBAR_RENDER_CYCLES", "20"))
        results = []
        for cycle in range(cycles):
            response = ipc("run", str(work) if cycle == 0 else "")
            assert response.returncode == 0, (response.stderr, str(work))
            results.append(json.loads(response.stdout))
        ipc("collect")
        after = measure()
        errors = re.findall(r"^.*(?:WARN scene|TypeError:|ReferenceError:|Binding loop).*$",
            (work / "shell.log").read_text(), re.MULTILINE)
        report = {"passed": all(result["passed"] for result in results) and not errors,
            "cycles": cycles, "before": before, "after": after, "results": results, "errors": errors}
        (work / "result.json").write_text(json.dumps(report, indent=2))
        print(f"Artifacts: {work}")
        print(json.dumps({key: report[key] for key in ("passed", "cycles", "before", "after")}))
        assert report["passed"], "Stationary toolbar pixels changed; see result.json"
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=3)
