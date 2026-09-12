#!/usr/bin/env python3
"""Exercise actual toolbar/popups on private D-Bus with a fake native tray item.

The system bus is redirected too: no real radios, clipboard, notification
history or production windows are touched by the component test.
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


def fake_tray():
    import ctypes
    import dbus
    import dbus.service
    from dbus.mainloop.glib import DBusGMainLoop

    DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    name = dbus.service.BusName("org.test.ToolbarWidthTray", bus)

    class TrayItem(dbus.service.Object):
        @dbus.service.method("org.freedesktop.DBus.Properties", in_signature="s", out_signature="a{sv}")
        def GetAll(self, interface):
            return {"Category": "ApplicationStatus", "Id": "width-test", "Title": "Test treja",
                    "Status": "Active", "WindowId": dbus.UInt32(0),
                    "IconName": "application-x-executable", "ItemIsMenu": False,
                    "Menu": dbus.ObjectPath("/Menu")}

        @dbus.service.method("org.freedesktop.DBus.Properties", in_signature="ss", out_signature="v")
        def Get(self, interface, key):
            return self.GetAll(interface)[key]

    item = TrayItem(bus, "/StatusNotifierItem")
    watcher = dbus.Interface(bus.get_object("org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher"),
                             "org.kde.StatusNotifierWatcher")
    watcher.RegisterStatusNotifierItem(str(name.get_name()))
    glib = ctypes.CDLL("libglib-2.0.so.0")
    glib.g_main_loop_new.argtypes = [ctypes.c_void_p, ctypes.c_int]
    glib.g_main_loop_new.restype = ctypes.c_void_p
    glib.g_main_loop_run.argtypes = [ctypes.c_void_p]
    glib.g_main_loop_run(glib.g_main_loop_new(None, False))


if "--tray-fixture" in sys.argv:
    fake_tray()
    raise SystemExit(0)

if os.environ.get("QS_WIDTH_PRIVATE_BUS") != "1":
    with tempfile.TemporaryDirectory(prefix="quickshell-width-bus-") as directory:
        bus_config = Path(directory) / "bus.conf"
        # No service activation directories: private test clients cannot start
        # desktop portals or other session helpers from the user's environment.
        bus_config.write_text('''<busconfig><type>session</type><listen>unix:tmpdir=/tmp</listen>
<policy context="default"><allow send_destination="*"/><allow receive_sender="*"/>
<allow own="*"/></policy></busconfig>''')
        raise SystemExit(subprocess.call(["dbus-run-session", "--config-file", str(bus_config),
                                          "--", sys.executable, __file__],
                                         env=dict(os.environ, QS_WIDTH_PRIVATE_BUS="1")))

root = Path(__file__).resolve().parents[1]
work = Path(tempfile.mkdtemp(prefix="quickshell-toolbar-width-"))
config = work / "shell"
shutil.copytree(root, config)
shutil.copy2(config / "tests/fixtures/toolbar-width.qml", config / "shell.qml")
(config / "services/HyprlandService.qml").write_text('''pragma Singleton
import Quickshell
Singleton { function screenName(screen) { return "width-test"; } }
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
    tray = None

    def ipc(function):
        return subprocess.run(["qs", "ipc", "--pid", str(proc.pid), "call", "widthtest", function],
                              env=env, text=True, capture_output=True, timeout=10)

    try:
        deadline = time.monotonic() + 10
        while True:
            result = ipc("ready")
            if result.returncode == 0 and result.stdout.strip() in ("true", "false"):
                break
            assert proc.poll() is None and time.monotonic() < deadline, f"Startup failed: {work}"
            time.sleep(.05)
        tray = subprocess.Popen([sys.executable, __file__, "--tray-fixture"], env=env,
                                stdout=log, stderr=log)
        while ipc("ready").stdout.strip() != "true":
            assert tray.poll() is None and time.monotonic() < deadline, f"Tray failed: {work}"
            time.sleep(.05)
        cycles = int(os.environ.get("QS_WIDTH_TEST_CYCLES", "20"))
        for cycle in range(cycles):
            result = ipc("run")
            assert result.returncode == 0, (result.stdout, result.stderr, work)
            checks = json.loads(result.stdout)
            assert checks["passed"], {"cycle": cycle + 1, "logs": str(work), **checks}
        errors = re.findall(r"^.*(?:WARN scene|TypeError:|ReferenceError:|Binding loop).*$",
                            (work / "shell.log").read_text(), re.MULTILINE)
        assert not errors, {"qml_errors": errors, "logs": str(work)}
        (work / "result.json").write_text(json.dumps({"cycles": cycles, **checks}, indent=2))
        print(f"PASS: {cycles} cycles; all 10 panels keep a 410 px frame and 402 px content, including Bluetooth after screen resize")
        print("Verified: narrow collapsed toolbar, native tray overflow, audio/brightness, calendar handoffs,")
        print("animation steps, layout settling and Loader destruction after closing.")
        print(f"Logs: {work}")
    finally:
        for child in (tray, proc):
            if child is not None:
                child.terminate()
                try:
                    child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=3)
