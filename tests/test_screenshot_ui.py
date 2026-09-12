#!/usr/bin/env python3
"""Exercise screenshot selection on synthetic pixels and an in-memory controller.

No compositor capture, clipboard access, user image, production bus, or live shell.
"""
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile
import time
import zlib


root = Path(__file__).resolve().parents[1]
work = Path(tempfile.mkdtemp(prefix="quickshell-screenshot-ui-"))
config = work / "shell"
for directory, names in {
    "core": ["Theme", "Metrics", "Strings", "Icons"],
    "components": ["ActionButton"],
    "modules/screenshot": ["ScreenshotOverlay"],
}.items():
    target = config / directory
    target.mkdir(parents=True)
    entries = [f"module qs.{directory.replace('/', '.')}"]
    for name in names:
        shutil.copy2(root / directory / f"{name}.qml", target / f"{name}.qml")
        entries.append(f"{'singleton ' if directory == 'core' else ''}{name} 1.0 {name}.qml")
    (target / "qmldir").write_text("\n".join(entries) + "\n")
shutil.copy2(root / "modules/screenshot/SelectionGeometry.js", config / "modules/screenshot/SelectionGeometry.js")
# Quickshell's PanelWindow has no offscreen backend. Adapt only the window shell
# in the temporary copy; all production view content and handlers stay intact.
# Native Wayland layer/focus behavior is covered by the integration acceptance.
overlay = config / "modules/screenshot/ScreenshotOverlay.qml"
overlay_text = overlay.read_text().replace("PanelWindow {", "FloatingWindow {", 1)
overlay_text = overlay_text.replace("    anchors { top: true; bottom: true; left: true; right: true }\n", "")
overlay_text = re.sub(r"^    (?:exclusionMode:|WlrLayershell\.).*\n", "", overlay_text, flags=re.MULTILINE)
overlay_text = overlay_text.replace("    screen: shellScreen\n", "    screen: shellScreen\n    implicitWidth: 800\n    implicitHeight: 600\n")
overlay.write_text(overlay_text)
with (config / "core/qmldir").open("a") as module:
    module.write("singleton Settings 1.0 Settings.qml\n")
(config / "core/Settings.qml").write_text("""pragma Singleton
import Quickshell
Singleton {
 property bool reducedMotion: true
 property real surfaceOpacity: 0.90
 property real interactiveOpacity: 0
}""")
shutil.copy2(root / "tests/fixtures/screenshot-ui.qml", config / "shell.qml")

# Deterministic, plainly synthetic image; never reads the user's desktop.
def chunk(kind, data):
    return struct.pack("!I", len(data)) + kind + data + struct.pack("!I", zlib.crc32(kind + data))


rows = bytearray()
for y in range(600):
    rows.append(0)
    for x in range(800):
        rows.extend((30 + x * 60 // 800, 30 + y * 70 // 600, 75 + (x + y) * 40 // 1400))
source = work / "synthetic.png"
source.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack("!2I5B", 800, 600, 8, 2, 0, 0, 0))
                   + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))
runtime = work / "runtime"
runtime.mkdir(mode=0o700)
env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_QPA_PLATFORMTHEME="", NO_AT_BRIDGE="1",
           WAYLAND_DISPLAY="", HYPRLAND_INSTANCE_SIGNATURE="", DBUS_SYSTEM_BUS_ADDRESS="unix:path=/nonexistent",
           XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(work / "config"),
           XDG_STATE_HOME=str(work / "state"), XDG_CACHE_HOME=str(work / "cache"),
           QS_SCREENSHOT_IMAGE=source.as_uri(), QS_SCREENSHOT_PROOF=str(work))
bus = subprocess.Popen(["dbus-daemon", "--session", "--nofork", "--print-address=1"],
                       env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
env["DBUS_SESSION_BUS_ADDRESS"] = bus.stdout.readline().strip()
assert env["DBUS_SESSION_BUS_ADDRESS"].startswith("unix:"), "Private test bus failed to start"

with (work / "shell.log").open("w") as log:
    proc = subprocess.Popen(["qs", "-p", str(config), "--no-color"], env=env, stdout=log, stderr=log)

    def ipc(function):
        result = subprocess.run(["qs", "ipc", "--pid", str(proc.pid), "call", "screenshottest", function],
                                env=env, text=True, capture_output=True, timeout=20)
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
        assert ipc("ready") == "true", (work / "shell.log").read_text()
        cold = measure()
        result = json.loads(ipc("run"))
        assert result["passed"], {"logs": str(work), **result}
        before = measure()
        cycles = int(os.environ.get("QS_SCREENSHOT_UI_CYCLES", "20"))
        memory = []
        for cycle in range(cycles):
            result = json.loads(ipc("cycle"))
            assert result["passed"], {"cycle": cycle + 1, "logs": str(work), **result}
            memory.append(int((Path("/proc") / str(proc.pid) / "stat").read_text().split()[23]) *
                          os.sysconf("SC_PAGE_SIZE") // 1024)
        after = measure()
        assert ipc("proof") == "true"
        assert all((work / f"{mode}.png").is_file() for mode in ("region", "window", "monitor", "compact"))
        errors = re.findall(r"^.*(?:WARN scene|TypeError:|ReferenceError:|Binding loop|Cannot assign|Unable to assign).*$",
                            (work / "shell.log").read_text(), re.MULTILINE)
        errors = [line for line in errors if not ("screenshot-missing-fixture.png" in line
                  and "Cannot open" in line)]
        assert not errors, {"qml_errors": errors, "logs": str(work)}
        summary = {"cycles": cycles, "cold": cold, "before": before, "after": after,
                   "rss_per_cycle_kib": memory, "passed": True}
        (work / "result.json").write_text(json.dumps(summary, indent=2))
        print(f"PASS: screenshot pointer/keyboard actions, geometry, scale, guards, focus, errors, and {cycles} lifecycle cycles")
        print(f"Private bus, offscreen windows, synthetic image and controller only. Evidence: {work}")
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=3)
        bus.terminate()
        bus.wait(timeout=3)
