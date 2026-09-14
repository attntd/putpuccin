#!/usr/bin/env python3
"""Exercise power confirmation UI with an allowlist-only, in-memory service.

No production services, system commands or notification servers are imported.
The private runtime/config and offscreen platform also isolate the desktop.
"""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time


root = Path(__file__).resolve().parents[1]
work = Path(tempfile.mkdtemp(prefix="quickshell-power-confirm-"))
config = work / "shell"
modules = {
    "core": ["Theme", "Metrics", "Motion", "Strings", "Icons"],
    "components": ["ActionButton", "PopupFrame", "KeyboardNavigation", "RevealSection"],
    "popups": ["PowerPopup"],
}
for directory, names in modules.items():
    target = config / directory
    target.mkdir(parents=True)
    entries = [f"module qs.{directory}"]
    for name in names:
        shutil.copy2(root / directory / f"{name}.qml", target / f"{name}.qml")
        entries.append(f"{'singleton ' if directory == 'core' else ''}{name} 1.0 {name}.qml")
    (target / "qmldir").write_text("\n".join(entries) + "\n")

with (config / "core/qmldir").open("a") as module:
    module.write("singleton Settings 1.0 Settings.qml\nsingleton SurfaceManager 1.0 SurfaceManager.qml\n")
(config / "core/Settings.qml").write_text('''pragma Singleton
import Quickshell
Singleton {
 property bool reducedMotion: false
 property real surfaceOpacity: 0.90
 property real interactiveOpacity: 0
}''')
(config / "core/SurfaceManager.qml").write_text('''pragma Singleton
import Quickshell
Singleton {
 signal changed(string screenName, string surfaceId)
 function closeOn(screenName) { changed(screenName, ""); }
}''')
(config / "services").mkdir()
(config / "services/qmldir").write_text("module qs.services\nsingleton SystemActions 1.0 SystemActions.qml\n")
(config / "services/SystemActions.qml").write_text('''pragma Singleton
import Quickshell
Singleton {
 property bool busy: false
 property string errorMessage: ""
 property string unavailableAction: ""
 property var executed: []
 signal succeeded(string actionId)
 function available(actionId) {
   return ["lock", "logout", "suspend", "hibernate", "reboot", "poweroff"].indexOf(actionId) >= 0
       && actionId !== unavailableAction;
 }
 function execute(actionId) {
   if (busy || !available(actionId)) return;
   executed = executed.concat([actionId]);
 }
 function reset() { busy = false; errorMessage = ""; unavailableAction = ""; executed = []; }
}''')
shutil.copy2(root / "tests/fixtures/power-confirmation.qml", config / "shell.qml")
baseline = os.environ.get("QS_POWER_BASELINE")
if baseline:
    shutil.copy2(baseline, config / "popups/PowerPopup.qml")
runtime = work / "runtime"
runtime.mkdir(mode=0o700)
env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_QPA_PLATFORMTHEME="", NO_AT_BRIDGE="1",
           WAYLAND_DISPLAY="", HYPRLAND_INSTANCE_SIGNATURE="", DBUS_SESSION_BUS_ADDRESS="unix:path=/nonexistent",
           DBUS_SYSTEM_BUS_ADDRESS="unix:path=/nonexistent", XDG_RUNTIME_DIR=str(runtime),
           XDG_CONFIG_HOME=str(work / "config"), XDG_STATE_HOME=str(work / "state"),
           XDG_CACHE_HOME=str(work / "cache"), QS_POWER_PROOF=str(work))

with (work / "shell.log").open("w") as log:
    proc = subprocess.Popen(["qs", "-p", str(config), "--no-color"], env=env, stdout=log, stderr=log)

    def ipc(function, *args):
        result = subprocess.run(["qs", "ipc", "--pid", str(proc.pid), "call", "powertest", function,
                                 *[str(arg).lower() if isinstance(arg, bool) else str(arg) for arg in args]],
                                env=env, text=True, capture_output=True, timeout=15)
        assert result.returncode == 0, (result.stdout, result.stderr, work)
        return result.stdout.strip()

    def measure():
        def sample():
            stat = (Path("/proc") / str(proc.pid) / "stat").read_text().split()
            return int(stat[13]) + int(stat[14]), int(stat[23]) * os.sysconf("SC_PAGE_SIZE") // 1024
        ticks, _ = sample()
        start = time.monotonic()
        time.sleep(1)
        after, rss = sample()
        return {"cpu_percent": round((after - ticks) / os.sysconf("SC_CLK_TCK") /
                                     (time.monotonic() - start) * 100, 2), "rss_kib": rss}

    try:
        deadline = time.monotonic() + 10
        while not list(runtime.glob("quickshell/by-id/*/instance.lock")):
            assert proc.poll() is None and time.monotonic() < deadline, f"Startup failed: {work}"
            time.sleep(.05)
        assert ipc("ready") == "true"
        before = measure()
        cycles = int(os.environ.get("QS_POWER_TEST_CYCLES", "20"))
        memory = []
        for cycle in range(cycles):
            result = json.loads(ipc("smoke" if baseline else "run", cycle % 2 == 1))
            assert result["passed"], {"cycle": cycle + 1, "logs": str(work), **result}
            memory.append(int((Path("/proc") / str(proc.pid) / "stat").read_text().split()[23]) *
                          os.sysconf("SC_PAGE_SIZE") // 1024)
        after = measure()
        if not baseline:
            assert ipc("screenshots") == "true"
            time.sleep(.2)
            assert all((work / f"{action}.png").is_file() for action in ("logout", "reboot", "poweroff"))
        errors = re.findall(r"^.*(?:WARN scene|TypeError:|ReferenceError:|Binding loop).*$",
                            (work / "shell.log").read_text(), re.MULTILINE)
        assert not errors, {"qml_errors": errors, "logs": str(work)}
        summary = {"cycles": cycles, "baseline": bool(baseline), "before": before, "after": after,
                   "rss_per_cycle_kib": memory, **result}
        (work / "result.json").write_text(json.dumps(summary, indent=2))
        print(f"PASS: {cycles} cycles; {'baseline lifecycle' if baseline else 'inline geometry, selection, cancellation, keyboard, guards and lifecycle'}")
        print(f"All executions used only the in-memory SystemActions mock. Evidence: {work}")
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=3)
