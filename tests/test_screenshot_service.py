#!/usr/bin/env python3
"""Real screenshot service + helper, private bus, native virtual Qt screens.

Only the Hyprland import is replaced in the service copy. The fixture server
answers its actual one-shot Unix socket requests. Capture PNGs are synthetic;
clipboard, notification, opener and editor commands never reach the live session.
"""
import hashlib
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import socket
import struct
import subprocess
import tempfile
import threading
import time
import zlib


root = Path(__file__).resolve().parents[1]
work = Path(tempfile.mkdtemp(prefix="quickshell-screenshot-service-"))
config = work / "shell"
shutil.copytree(root / "integrations/ScreenshotNative", config / "integrations/ScreenshotNative")
for directory in ("core", "services", "fixture", "scripts"):
    (config / directory).mkdir(parents=True)
(work / "bin").mkdir()
(work / "runtime").mkdir(mode=0o700)
(config / "core/qmldir").write_text("module qs.core\nsingleton Settings 1.0 Settings.qml\nsingleton Strings 1.0 Strings.qml\n")
(config / "services/qmldir").write_text("module qs.services\nsingleton ScreenshotService 1.0 ScreenshotService.qml\nsingleton LockService 1.0 LockService.qml\n")
(config / "fixture/qmldir").write_text("module qs.fixture\nsingleton Hyprland 1.0 Hyprland.qml\nGlobalShortcut 1.0 GlobalShortcut.qml\n")
(config / "core/Settings.qml").write_text("""pragma Singleton
import Quickshell
Singleton {
 property bool screenshotPaintCursor: true
 property string screenshotDirectory: Quickshell.env("QS_TEST_DESTINATION")
}""")
(config / "services/LockService.qml").write_text("""pragma Singleton
import Quickshell
Singleton { property bool locked: false; property bool releasing: false }
""")
(config / "fixture/Hyprland.qml").write_text("""pragma Singleton
import Quickshell
Singleton {
 property string requestSocketPath: Quickshell.env("QS_TEST_SOCKET")
 property var focusedMonitor: ({name: "fixture-main"})
 signal rawEvent(var event)
}""")
(config / "fixture/GlobalShortcut.qml").write_text('import QtQuick\nQtObject { property string appid; property string name; property string description; signal pressed() }\n')
service = (root / "services/ScreenshotService.qml").read_text()
# Trigger cancellation synchronously when the real worker starts: this tests
# the race without depending on how fast a particular CPU encodes the image.
service = service.replace('    id: root\n', '    id: root\n    property bool cancelNativeOnce: false\n', 1)
service = service.replace('        id: encoder\n', '        id: encoder\n        onBusyChanged: if (busy && root.cancelNativeOnce) { root.cancelNativeOnce = false; root.cancel(); }\n', 1)
assert service.count("import Quickshell.Hyprland") == 1
(config / "services/ScreenshotService.qml").write_text(service.replace("import Quickshell.Hyprland", "import qs.fixture"))
shutil.copy2(root / "core/Strings.qml", config / "core/Strings.qml")
shutil.copy2(root / "tests/fixtures/screenshot-service.qml", config / "shell.qml")
shutil.copy2(root / "scripts/screenshot-action", config / "scripts/screenshot-action-real")

# A fault-injection wrapper preserves the real helper's prepare/crop/finish and
# cleanup behavior. It only delays a requested operation or returns its error.
(config / "scripts/screenshot-action").write_text("""#!/usr/bin/env python3
import json, os, pathlib, signal, subprocess, sys, time
base = pathlib.Path(os.environ['QS_TEST_WORK'])
control = json.loads((base / 'control.json').read_text())
operation = sys.argv[1]
def event(stage, **extra):
 with (base / 'helper.jsonl').open('a') as stream:
  stream.write(json.dumps(dict(stage=stage, operation=operation, args=sys.argv[2:], **extra)) + '\\n')
def terminated(*_):
 event('sigterm')
 if not control.get('ignoreTerm', False):
  raise SystemExit(1)
signal.signal(signal.SIGTERM, terminated)
event('start')
if control.get('delayOperation') == operation:
 time.sleep(control.get('delaySeconds', .5))
if control.get('failOperation') == operation:
 result = dict(ok=False, code=control.get('errorCode', operation + '_failed'))
 code = 1
else:
 done = subprocess.run([str(pathlib.Path(__file__).with_name('screenshot-action-real')), *sys.argv[1:]],
                       text=True, capture_output=True, timeout=20)
 try: result = json.loads(done.stdout)
 except ValueError: result = dict(ok=False, code='fixture_invalid_reply')
 code = done.returncode
 if operation == 'prepare' and result.get('ok'):
  result['editorAvailable'] = bool(control.get('editorAvailable', False))
event('end', result=result, exitCode=code)
print(json.dumps(result), flush=True)
sys.exit(code)
""")
(config / "scripts/screenshot-action").chmod(0o755)
stub = """#!/usr/bin/env python3
import hashlib, json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
data = sys.stdin.buffer.read() if name == 'wl-copy' else b''
if name == 'wl-copy':
 (pathlib.Path(os.environ['QS_TEST_WORK']) / 'clipboard.png').write_bytes(data)
with (pathlib.Path(os.environ['QS_TEST_WORK']) / 'external.jsonl').open('a') as stream:
 stream.write(json.dumps(dict(command=name, args=sys.argv[1:], bytes=len(data), sha256=hashlib.sha256(data).hexdigest())) + '\\n')
sys.exit(0)
"""
for command in ("wl-copy", "notify-send", "xdg-open", "satty"):
    path = work / "bin" / command
    path.write_text(stub)
    path.chmod(0o755)

# Qt's own offscreen backend supplies real Quickshell ShellScreen instances with
# negative positions. No replacement of Quickshell.screens or service internals.
# Qt 6.11 source documents offscreen:configfile and its screen geometry keys.
screen_config = dict(windowFrameMargins=False, screens=[
    dict(name="fixture-left", x=-640, y=-120, width=640, height=480, dpr=1),
    dict(name="fixture-main", x=0, y=0, width=800, height=600, dpr=1),
])
(work / "screens.json").write_text(json.dumps(screen_config))
monitors = [dict(name="fixture-left", disabled=False, dpmsStatus=True,
                 activeWorkspace=dict(id=1), specialWorkspace=dict(id=0)),
            dict(name="fixture-main", disabled=False, dpmsStatus=True,
                 activeWorkspace=dict(id=2), specialWorkspace=dict(id=-99))]


def client(address, workspace, at, size, **extra):
    return dict(address=address, workspace=dict(id=workspace), at=at, size=size,
                mapped=extra.get("mapped", True), hidden=extra.get("hidden", False),
                pinned=extra.get("pinned", False), floating=extra.get("floating", False),
                focusHistoryID=extra.get("focus", 5), title=address)


clients = [client("left", 1, [-620, -100], [200, 120]),
           client("clipped", 1, [-670, -160], [100, 100], focus=1),
           client("spanning", 1, [-40, 20], [150, 100], floating=True, focus=3),
           client("tile", 2, [40, 60], [400, 300], focus=2),
           client("floating", 2, [100, 100], [180, 140], floating=True),
           client("special", -99, [80, 80], [120, 80]),
           client("pinned", 99, [740, 40], [100, 90], pinned=True),
           client("hidden", 2, [10, 10], [100, 100], hidden=True),
           client("unmapped", 2, [10, 10], [100, 100], mapped=False),
           client("other-workspace", 3, [10, 10], [100, 100]),
           client("offscreen", 2, [1300, 0], [100, 100])]
requests = []
server_errors = []
stop = threading.Event()
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(str(work / "hypr.sock"))
server.listen(8)
server.settimeout(.1)


def serve():
    while not stop.is_set():
        try:
            connection, _ = server.accept()
        except socket.timeout:
            continue
        except OSError:
            break
        try:
            with connection:
                connection.settimeout(2)
                command = connection.recv(1024).decode()
                requests.append(command)
                assert command in ("j/monitors", "j/clients"), command
                data = json.dumps(monitors if command == "j/monitors" else clients).encode()
                midpoint = len(data) // 2
                connection.sendall(data[:midpoint])
                time.sleep(.015)  # Exercise partial JSON, as a real stream may deliver it.
                connection.sendall(data[midpoint:])
                # The client owns normal close once the JSON reply is complete.
                connection.recv(1)
        except (BrokenPipeError, ConnectionResetError):
            pass  # Expected if cancel closes a pending metadata request.
        except Exception as error:
            server_errors.append(str(error))


thread = threading.Thread(target=serve, daemon=True)
thread.start()
(work / "control.json").write_text("{}")
env = dict(os.environ, QML_IMPORT_PATH=str(config / "integrations"), QT_QPA_PLATFORM=f"offscreen:configfile={work / 'screens.json'}",
           QT_QPA_OFFSCREEN_NO_GLX="1", QT_QPA_PLATFORMTHEME="", NO_AT_BRIDGE="1",
           WAYLAND_DISPLAY="", DISPLAY="", HYPRLAND_INSTANCE_SIGNATURE="",
           DBUS_SYSTEM_BUS_ADDRESS="unix:path=/nonexistent", XDG_RUNTIME_DIR=str(work / "runtime"),
           XDG_CONFIG_HOME=str(work / "config"), XDG_STATE_HOME=str(work / "state"),
           XDG_CACHE_HOME=str(work / "cache"), PATH=str(work / "bin") + ":" + os.environ["PATH"],
           QS_TEST_WORK=str(work), QS_TEST_SOCKET=str(work / "hypr.sock"),
           QS_TEST_DESTINATION=str(work / "screenshots with spaces"))
bus = subprocess.Popen(["dbus-daemon", "--session", "--nofork", "--print-address=1"], env=env,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
env["DBUS_SESSION_BUS_ADDRESS"] = bus.stdout.readline().strip()
assert env["DBUS_SESSION_BUS_ADDRESS"].startswith("unix:"), "Private D-Bus failed to start"
log = (work / "shell.log").open("w")
proc = subprocess.Popen(["qs", "-p", str(config), "--no-color"], env=env, stdout=log, stderr=log)


def ipc(method, *args):
    values = [str(value).lower() if isinstance(value, bool) else str(value) for value in args]
    result = subprocess.run(["qs", "ipc", "--pid", str(proc.pid), "call", "screenshotservicetest", method, *values],
                            env=env, text=True, capture_output=True, timeout=10)
    assert result.returncode == 0, (result.stdout, result.stderr, work)
    return result.stdout.strip()


def snapshot():
    return json.loads(ipc("snapshot"))


def wait_for(check, timeout=4):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        assert proc.poll() is None, (work / "shell.log").read_text()
        result = check()
        if result:
            return result
        time.sleep(.025)
    raise AssertionError(dict(timeout=timeout, state=snapshot(), evidence=str(work)))


def phase(name):
    return wait_for(lambda: (current if (current := snapshot())["phase"] == name else None))


def control(**values):
    (work / "control.json").write_text(json.dumps(values))


def events(filename="helper.jsonl"):
    path = work / filename
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def png(width, height):
    def chunk(kind, data):
        return struct.pack("!I", len(data)) + kind + data + struct.pack("!I", zlib.crc32(kind + data))
    row = b"\0" + bytes((70, 80, 120)) * width
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack("!2I5B", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(row * height)) + chunk(b"IEND", b""))


def deliver(current):
    for record in current["screens"]:
        dimensions = (round(record["width"] * 1.2), round(record["height"] * 1.2))
        if not snapshot()["screens"][current["screens"].index(record)]["url"]:
            ipc("captured", record["name"], *dimensions, current["generation"])
    return phase("selecting")


def start(mode="region", screen="fixture-main"):
    assert ipc("begin", mode, screen) == "true"
    return deliver(phase("capturing"))


def finish_cancel(current):
    ipc("cancel")
    assert snapshot()["phase"] == "idle"
    if current["directory"]:
        assert snapshot()["directory"] == ""


passed = []
try:
    deadline = time.monotonic() + 10
    while not list((work / "runtime").glob("quickshell/by-id/*/instance.lock")):
        assert proc.poll() is None and time.monotonic() < deadline, str(work)
        time.sleep(.025)
    initial = snapshot()
    assert initial["phase"] == "idle" and len(initial["nativeScreens"]) == 2, initial
    assert initial["nativeScreens"][0] == dict(name="fixture-left", x=-640, y=-120, width=640, height=480)
    labels = initial["labels"]

    # 1. Real IPC metadata and capture handshake. Each screen must finish before selection.
    ipc("gate", True)
    assert ipc("begin", "region", "fixture-left") == "true"
    pending = snapshot()
    assert pending["phase"] == "preparing"
    ipc("metadata", "monitors", "{}", pending["generation"] - 1)
    assert snapshot()["active"], "Stale invalid metadata aborted the current preparation"
    ipc("gate", False)
    current = phase("capturing")
    assert sorted(requests) == ["j/clients", "j/monitors"], requests
    by_id = {entry["id"]: entry for entry in current["windows"]}
    assert set(by_id) == {"left:fixture-left", "clipped:fixture-left", "tile:fixture-main",
                          "floating:fixture-main", "special:fixture-main", "pinned:fixture-main",
                          "spanning:fixture-left", "spanning:fixture-main"}, by_id
    for name, rect in (("left:fixture-left", (20, 20, 200, 120)),
                       ("clipped:fixture-left", (0, 0, 70, 60)),
                       ("pinned:fixture-main", (740, 40, 60, 90)),
                       ("spanning:fixture-left", (600, 140, 40, 100)),
                       ("spanning:fixture-main", (0, 20, 110, 100))):
        assert tuple(by_id[name][key] for key in ("x", "y", "width", "height")) == rect, by_id[name]
    main = [entry["id"] for entry in current["windows"] if entry["screenName"] == "fixture-main"]
    assert main[:3] == ["special:fixture-main", "spanning:fixture-main", "floating:fixture-main"], main
    ipc("captured", "fixture-left", 768, 576, current["generation"] - 1)
    assert all(not record["url"] for record in snapshot()["screens"]), "Stale capture was accepted"
    first = current["screens"][0]
    ipc("captured", first["name"], 768, 576, current["generation"])
    assert snapshot()["phase"] == "capturing", "Selection began before every screen finished"
    current = deliver(current)
    assert current["paintCursor"] and not current["hasSelection"]
    assert current["directory"] == "" and not events(), "Opening launched an I/O helper"
    assert ipc("select", "fixture-main", 100, 100, -40, -20) == "true"
    selection = snapshot()["selection"]
    assert selection == dict(screenName="fixture-main", x=60, y=80, width=40, height=20), selection
    assert ipc("invalidRegion", "fixture-main") == "false" and snapshot()["selection"] == selection
    finish_cancel(current)
    passed.append("metadata_local_coordinates_workspace_filter_stacking_and_capture_handshake")

    # Cancel preparation triggered by an action, including a late directory.
    control(delayOperation="prepare", delaySeconds=.6, ignoreTerm=True)
    current = start("monitor")
    before_count = len(events())
    assert ipc("perform", "copy") == "true"
    wait_for(lambda: any(entry["stage"] == "start" and entry["operation"] == "prepare"
                         for entry in events()[before_count:]))
    ipc("cancel")
    assert ipc("begin", "region", "fixture-main") == "false"
    ipc("metadata", "monitors", "[]", current["generation"])
    ipc("captured", "fixture-main", 960, 720, current["generation"])
    ended = wait_for(lambda: next((entry for entry in events()[before_count:]
        if entry["stage"] == "end" and entry["operation"] == "prepare"), None))
    wait_for(lambda: not Path(ended["result"]["directory"]).exists())
    assert not snapshot()["active"] and snapshot()["screens"] == []
    passed.append("cancel_during_prepare_cleans_late_directory_and_rejects_stale_results")

    # Preparation failure preserves the in-memory frame and selection for retry.
    control(failOperation="prepare", errorCode="prepare_failed")
    current = start()
    assert ipc("select", "fixture-main", 1, 1, 21, 19) == "true"
    selected = snapshot()["selection"]
    assert ipc("perform", "copy") == "true"
    failed = phase("selecting")
    assert failed["selection"] == selected and failed["directory"] == ""
    assert failed["errorMessage"] == labels["prepare"]
    passed.append("prepare_failure_keeps_memory_frame_and_selection")

    # The real native encoder writes exact physical pixels; helper errors keep
    # the original grab available. Holding the actual session lock forces an
    # encoder failure without mocking its implementation.
    control(failOperation="finish", errorCode="clipboard_missing")
    assert ipc("perform", "copy") == "true"
    failed = phase("selecting")
    directory = Path(failed["directory"])
    assert failed["selection"] == selected and failed["errorMessage"] == labels["clipboard"]
    assert struct.unpack("!II", (directory / "result.png").read_bytes()[16:24]) == (26, 23)
    with (directory / ".session").open("r+") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        assert ipc("perform", "copy") == "true"
        failed = phase("selecting")
        assert failed["selection"] == selected and failed["errorMessage"] == labels["crop"]
    control()
    assert ipc("perform", "copy") == "true"
    phase("idle")
    wait_for(lambda: not directory.exists())
    copied = work / "clipboard.png"
    assert struct.unpack("!II", copied.read_bytes()[16:24]) == (26, 23)
    decoded = subprocess.run(["magick", str(copied), "-depth", "8", "rgb:-"],
                             env=env, capture_output=True, check=True, timeout=5).stdout
    assert decoded == bytes((70, 80, 120)) * 26 * 23
    passed.append("native_export_lock_failure_and_clipboard_failure_allow_exact_pixel_retry")

    # A slow finish cannot publish a result after cancellation.
    control(delayOperation="finish", delaySeconds=.6)
    current = start("monitor")
    before_count = len(events())
    assert ipc("perform", "copy") == "true"
    wait_for(lambda: any(entry["stage"] == "start" and entry["operation"] == "finish"
                         for entry in events()[before_count:]))
    directory = Path(snapshot()["directory"])
    ipc("cancel")
    wait_for(lambda: not directory.exists())
    assert not snapshot()["active"]
    control()
    passed.append("cancel_during_finish_stops_helper_and_cleans_export")

    control()
    current = start("monitor")
    before_count = len(events())
    ipc("cancelNative", True)
    assert ipc("perform", "copy") == "true"
    phase("idle")
    wait_for(lambda: not list((work / "runtime/quickshell-de-screenshots").glob("capture-*")))
    assert not any(entry["operation"] == "finish" for entry in events()[before_count:])
    passed.append("cancel_native_encoding_prevents_finish_and_releases_locked_session")

    # 6. Both stages of the lock prevent begin; changing lock state cancels active work.
    ipc("lock", True, False)
    assert ipc("begin", "region", "fixture-main") == "false" and snapshot()["errorMessage"] == labels["locked"]
    ipc("lock", False, True)
    assert ipc("begin", "region", "fixture-main") == "false"
    ipc("lock", False, False)
    current = start()
    ipc("lock", True, False)
    assert snapshot()["phase"] == "idle"
    assert snapshot()["directory"] == ""
    ipc("lock", False, False)
    current = start()
    ipc("lock", False, True)
    assert snapshot()["phase"] == "idle"
    assert snapshot()["directory"] == ""
    ipc("lock", False, False)
    passed.append("lock_and_releasing_block_begin_and_cancel_active_capture")

    # 8. Real save completion publishes only a temporary destination and keeps its path.
    control()
    current = start("monitor", "fixture-left")
    assert current["hasSelection"] and current["selection"]["width"] == 640
    assert ipc("perform", "save") == "true"
    saved = phase("idle")
    saved_path = Path(saved["lastSavedPath"])
    assert saved_path.parent == work / "screenshots with spaces" and saved_path.is_file()
    assert struct.unpack("!II", saved_path.read_bytes()[16:24]) == (768, 576)
    assert snapshot()["directory"] == ""
    passed.append("save_completion_persists_private_destination_and_last_path")

    assert not server_errors, server_errors
    errors = re.findall(r"^.*(?:WARN scene|TypeError:|ReferenceError:|Binding loop|Cannot assign|Unable to assign).*$",
                        (work / "shell.log").read_text(), re.MULTILINE)
    assert not errors, dict(qml_errors=errors, evidence=str(work))
    assert not any(entry["command"] in ("satty", "xdg-open") for entry in events("external.jsonl"))
    wait_for(lambda: not list((work / "runtime/quickshell-de-screenshots").glob("capture-*")))
    summary = dict(passed=passed, metadata_requests=len(requests), virtual_screens=initial["nativeScreens"],
                   clipboard_command_mocked=True, live_compositor_used=False)
    (work / "result.json").write_text(json.dumps(summary, indent=2))
    print(f"PASS: {len(passed)} screenshot service cases; real Unix IPC, Process, helper and virtual Qt screens")
    print(f"Private bus, synthetic PNGs, mocked clipboard/desktop commands. Evidence: {work}")
finally:
    proc.terminate()
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=3)
    bus.terminate()
    bus.wait(timeout=3)
    stop.set()
    server.close()
    thread.join(timeout=2)
    log.close()
