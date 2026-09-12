#!/usr/bin/env python3
"""Native Wayland startup/resize regression with fake notifications only.

Qt's pre-map polish pass differs from an offscreen Window. The old arrow
visibility/implicit-width feedback prevents even the first IPC reply.
No notification server, clipboard adapter or compositor shortcuts are loaded.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parents[1]
work = Path(tempfile.mkdtemp(prefix="quickshell-notification-layout-"))
config = work / "shell"
for directory in ("core", "components", "modules/notifications"):
    shutil.copytree(root / directory, config / directory)
(config / "services").mkdir()
(config / "services/qmldir").write_text("module qs.services\nsingleton NotificationService 1.0 NotificationService.qml\n")
(config / "services/NotificationService.qml").write_text('''pragma Singleton
import Quickshell
Singleton {
 property bool shown: true
 property bool longText: false
 property var visibleToasts: shown ? [{uid:"layout-test", screen:Quickshell.screens[0].name}] : []
 property bool canUndo: false
 property string undoScreen: ""
 function record(uid) { return {uid:uid, appName:"Test animacji", summary:"Rozwijanie powiadomienia",
  body:longText ? "Kontrola szerokości i układu powiadomienia. ".repeat(70) : "Kontrola płynności dolnej krawędzi.",
  time:0, urgency:1, actions:[]}; }
 function pauseToast(uid, paused) {}
 function activate(uid, action) {}
 function hideToast(uid) {}
 function discard(uid) {}
 function undo() {}
}''')
(config / "core/Settings.qml").write_text('''pragma Singleton
import Quickshell
Singleton {
 property int notificationWidth: 410
 property int topMargin: 8
 property int barHeight: 40
 property int sideMargin: 12
 property real surfaceOpacity: 0.84
 property real interactiveOpacity: 0
 property bool reducedMotion: false
}''')
(config / "core/SurfaceManager.qml").write_text('''pragma Singleton
import Quickshell
Singleton { function isOpen(surface, screen) { return false; } }
''')
# Keep normal blur/input behavior but never reuse a production layer namespace.
toasts = config / "modules/notifications/NotificationToasts.qml"
toasts.write_text(toasts.read_text().replace("quickshell-de:notifications", "quickshell-test:notification-layout"))
shutil.copy2(root / "tests/fixtures/notification-layout.qml", config / "shell.qml")
env = dict(os.environ, QT_QPA_PLATFORM="wayland", QT_QPA_PLATFORMTHEME="")
with (work / "shell.log").open("w+") as log:
    proc = subprocess.Popen(["qs", "-p", str(config), "--no-color"], env=env, stdout=log, stderr=log)
    def ipc(function, *args):
        return subprocess.run(["qs", "ipc", "--pid", str(proc.pid), "call", "layouttest", function,
                               *[str(a).lower() if isinstance(a, bool) else str(a) for a in args]],
                              env=env, text=True, capture_output=True, timeout=2)
    def status():
        result = ipc("status")
        return json.loads(result.stdout) if result.returncode == 0 and result.stdout.strip() else None
    try:
        deadline = time.monotonic() + 5
        while not (state := status()):
            assert proc.poll() is None and time.monotonic() < deadline, "Native shell did not start"
            time.sleep(.05)
        assert ipc('clickControls').stdout.strip() == 'true', 'Toast requires explicit click and retains selection'
        for cycle in range(20):
            for width in (80, 96, 121, 145, 200, 410, 640):
                result = ipc("configure", width, cycle % 2 == 1, True)
                assert result.returncode == 0, result.stderr
                time.sleep(.03)
                state = status()
                assert state and state["shown"] and state["buttonPresent"], state
                assert state["arrowVisible"] or not state["arrowEnabled"], state
                for expanded in (True, False):
                    assert ipc("expand", expanded).returncode == 0
                    time.sleep(.03)
                    assert status()["shown"]
            ipc("configure", 410, False, False)
            assert not status()["shown"]
            ipc("configure", 410, False, True)
            assert status()["shown"]
        # A bounded IPC round trip detects a stuck polish pass on every resize.
        print("PASS: native startup and 20 cycles of resize/text changes/expand/collapse/hide/remap; IPC remains responsive")
        print(f"Logs: {work}")
    except Exception:
        print(f"FAIL: see isolated fixture and log in {work}")
        raise
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=2)
