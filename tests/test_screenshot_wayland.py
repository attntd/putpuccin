#!/usr/bin/env python3
"""Native screenshot integration on two private, headless Hyprland outputs.

Requires an existing Hyprland parent only for the nested Wayland renderer. The
child has its own runtime, D-Bus, config, screenshot files, and clipboard. Its
default WAYLAND-1 output is disabled before mapping, and all output mutations go
directly to the verified child socket. Production outputs are never modified.
"""
from contextlib import suppress
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import socket
import struct
import sys
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
# Hyprland puts its long instance signature under runtime/hypr; AF_UNIX has a
# 108-byte path limit, so a descriptive temporary directory name does not fit.
WORK = Path(tempfile.mkdtemp(prefix="qsw-"))
RUNTIME = WORK / "r"
RUNTIME.mkdir(mode=0o700)
CAPTURE_BASE = RUNTIME / "quickshell-de-screenshots"
SHELL = WORK / "shell"
CONFIG = WORK / "hyprland.lua"
SUMMARY = {"passed": False, "work": str(WORK), "checks": []}


def compositor_ipc(path, command):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(3)
        connection.connect(str(path))
        connection.sendall(command.encode())
        chunks = []
        while block := connection.recv(65536):
            chunks.append(block)
        return b"".join(chunks).decode()


def production_state(path):
    monitors = json.loads(compositor_ipc(path, "j/monitors"))
    clients = json.loads(compositor_ipc(path, "j/clients"))
    return {
        "monitors": sorted((item["name"], item["width"], item["height"], item["x"],
                            item["y"], item["scale"], item["transform"]) for item in monitors),
        "nestedWindows": sorted(item["address"] for item in clients if item["class"] == "aquamarine"),
    }


def write_config(scale=1.2, transform=0):
    content = f'''hl.monitor({{ output = "WAYLAND-1", disabled = true }})
hl.monitor({{ output = "SCREENSHOT-A", mode = "1280x720@60", position = "0x0", scale = 1 }})
hl.monitor({{ output = "SCREENSHOT-B", mode = "1440x900@60", position = "1280x0", scale = {scale}, transform = {transform} }})
hl.config({{
    misc = {{ disable_hyprland_logo = true, disable_splash_rendering = true, force_default_wallpaper = 0 }},
    animations = {{ enabled = false }},
    xwayland = {{ enabled = false }},
    debug = {{ disable_logs = false }},
}})
hl.layer_rule({{ name = "screenshot-test-no-anim", match = {{ namespace = "^quickshell-de:screenshot$" }}, no_anim = true }})
'''
    temporary = CONFIG.with_suffix(".new")
    temporary.write_text(content)
    temporary.replace(CONFIG)


def wait_until(predicate, description, timeout=8):
    end = time.monotonic() + timeout
    last = None
    while time.monotonic() < end:
        try:
            last = predicate()
            if last:
                return last
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
            pass
        time.sleep(.05)
    raise AssertionError(f"{description}: timeout; last={last!r}; evidence={WORK}")


def png_size(data):
    assert data[:16] == b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR"
    return struct.unpack(">II", data[16:24])


def rgba(data):
    result = subprocess.run(["magick", "png:-", "-depth", "8", "rgba:-"], input=data,
                            capture_output=True, timeout=10, check=True)
    width, height = png_size(data)
    assert len(result.stdout) == width * height * 4
    return result.stdout


def raw_crop(data, source_width, x, y, width, height):
    return b"".join(data[((y + row) * source_width + x) * 4:
                        ((y + row) * source_width + x + width) * 4] for row in range(height))


def measure(process):
    def sample():
        fields = (Path("/proc") / str(process.pid) / "stat").read_text().rsplit(")", 1)[1].split()
        return int(fields[11]) + int(fields[12])
    start_ticks = sample()
    start = time.monotonic()
    time.sleep(1)
    elapsed = time.monotonic() - start
    result = {"cpu_percent": round((sample() - start_ticks) / os.sysconf("SC_CLK_TCK") / elapsed * 100, 2)}
    for line in (Path("/proc") / str(process.pid) / "smaps_rollup").read_text().splitlines():
        if line.startswith(("Rss:", "Pss:")):
            key, value, _ = line.split()
            result[key[:-1].lower() + "_kib"] = int(value)
    return result


def stop(process):
    if process and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)


def run():
    required = ("Hyprland", "qs", "dbus-daemon", "magick", "wl-copy", "wl-paste")
    assert all(shutil.which(name) for name in required), "Missing test dependency"
    assert os.environ.get("WAYLAND_DISPLAY") and os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"), "Run inside Hyprland"
    parent_runtime = Path(os.environ["XDG_RUNTIME_DIR"])
    parent_socket = parent_runtime / "hypr" / os.environ["HYPRLAND_INSTANCE_SIGNATURE"] / ".socket.sock"
    parent_display = Path(os.environ["WAYLAND_DISPLAY"])
    if not parent_display.is_absolute():
        parent_display = parent_runtime / parent_display
    before = production_state(parent_socket)

    write_config()
    for directory in ("core", "services", "modules/screenshot", "integrations/ScreenshotNative"):
        shutil.copytree(ROOT / directory, SHELL / directory)
    (SHELL / "components").mkdir()
    shutil.copy2(ROOT / "components/ActionButton.qml", SHELL / "components/ActionButton.qml")
    (SHELL / "components/qmldir").write_text("module qs.components\nActionButton 1.0 ActionButton.qml\n")
    (SHELL / "scripts").mkdir()
    shutil.copy2(ROOT / "scripts/screenshot-action", SHELL / "scripts/screenshot-action")
    shutil.copy2(ROOT / "tests/fixtures/screenshot-wayland.qml", SHELL / "shell.qml")
    if "--panels" in sys.argv:
        for directory in ("modules", "components", "popups", "scripts", "config", "assets"):
            shutil.copytree(ROOT / directory, SHELL / directory, dirs_exist_ok=True)
        fixture = (SHELL / "shell.qml").read_text()
        fixture = fixture.replace('import qs.core\n', 'import qs.core\nimport qs.components\nimport qs.modules.statusbar\nimport qs.modules.workspaces\n')
        fixture = fixture.replace('    Screenshot {}', '''    readonly property var coordinator: SurfaceManager
    Variants {
        model: Quickshell.screens
        StatusBar { required property var modelData; screen: modelData }
    }
    Variants {
        model: Quickshell.screens
        DetachedLauncher { required property var modelData; screen: modelData }
    }
    Variants {
        model: Quickshell.screens
        WorkspaceSwitcher { required property var modelData; shellScreen: modelData; screenName: modelData.name }
    }
    Screenshot {}''')
        (SHELL / "shell.qml").write_text(fixture)
    user_config = WORK / "config/quickshell-de"
    user_config.mkdir(parents=True)
    (user_config / "settings.json").write_text(json.dumps({"schemaVersion": 1, "reducedMotion": True}))

    env = dict(os.environ, QML_IMPORT_PATH=str(SHELL / "integrations"), XDG_RUNTIME_DIR=str(RUNTIME), XDG_CONFIG_HOME=str(WORK / "config"),
        XDG_STATE_HOME=str(WORK / "state"), XDG_CACHE_HOME=str(WORK / "cache"),
        WAYLAND_DISPLAY=str(parent_display), DISPLAY="", HYPRLAND_INSTANCE_SIGNATURE="",
        LIBSEAT_BACKEND="seatd", SEATD_SOCK=str(WORK / "no-seatd.sock"),
        AQ_DRM_DEVICES=str(WORK / "no-drm-device"), HYPRLAND_NO_SD_VARS="1",
        HYPRLAND_NO_SD_NOTIFY="1", HYPRLAND_NO_CRASHREPORTER="1", HYPRLAND_NO_RT="1",
        GSETTINGS_BACKEND="memory", QT_QPA_PLATFORM="wayland", QT_QPA_PLATFORMTHEME="", NO_AT_BRIDGE="1")
    for key in ("NOTIFY_SOCKET", "LISTEN_FDS", "LISTEN_PID", "WAYLAND_SOCKET"):
        env.pop(key, None)
    bus_config = WORK / "bus.conf"
    bus_config.write_text('<busconfig><type>session</type><listen>unix:tmpdir=/tmp</listen><policy context="default">'
                         '<allow send_destination="*"/><allow receive_sender="*"/><allow own="*"/></policy></busconfig>')
    bus = compositor = shell = None
    log_files = []
    try:
        bus = subprocess.Popen(["dbus-daemon", "--config-file=" + str(bus_config), "--nofork", "--print-address=1"],
                               env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        env["DBUS_SESSION_BUS_ADDRESS"] = bus.stdout.readline().strip()
        assert env["DBUS_SESSION_BUS_ADDRESS"].startswith("unix:"), "Private D-Bus failed"
        compositor_log = (WORK / "compositor.log").open("w")
        log_files.append(compositor_log)
        compositor = subprocess.Popen(["Hyprland", "-c", str(CONFIG)], env=env,
                                      stdout=compositor_log, stderr=compositor_log)

        def ready_socket():
            assert compositor.poll() is None, f"Nested compositor exited: {WORK}"
            for candidate in (RUNTIME / "hypr").glob("*/.socket.sock"):
                json.loads(compositor_ipc(candidate, "j/monitors"))
                return candidate
            return None

        child_socket = wait_until(ready_socket, "Nested compositor startup", 15)
        assert child_socket != parent_socket and child_socket.is_relative_to(RUNTIME)

        def command(value):
            # This assertion is intentionally on every mutation, not only startup.
            assert child_socket != parent_socket and child_socket.is_relative_to(RUNTIME)
            return compositor_ipc(child_socket, value)

        def monitors():
            return json.loads(command("j/monitors"))

        for name in ("SCREENSHOT-A", "SCREENSHOT-B"):
            assert command("output create headless " + name).strip() == "ok"
        wait_until(lambda: {item["name"] for item in monitors()} == {"SCREENSHOT-A", "SCREENSHOT-B"}, "Private outputs")
        assert command("configerrors").strip() == ""
        assert production_state(parent_socket) == before, "Nested compositor changed the production desktop"
        env.update(WAYLAND_DISPLAY=str(RUNTIME / "wayland-1"), HYPRLAND_INSTANCE_SIGNATURE=child_socket.parent.name)
        assert Path(env["WAYLAND_DISPLAY"]).is_relative_to(RUNTIME)
        shell_log = (WORK / "shell.log").open("w")
        log_files.append(shell_log)
        shell = subprocess.Popen(["qs", "-p", str(SHELL), "--no-color"], env=env, stdout=shell_log, stderr=shell_log)

        def call(target, method, *args):
            assert shell.poll() is None, f"Screenshot fixture exited: {WORK}"
            reply = subprocess.run(["qs", "ipc", "--pid", str(shell.pid), "call", target, method,
                                    *map(str, args)], env=env, capture_output=True, text=True, timeout=3)
            if reply.returncode:
                raise RuntimeError(f"{target}.{method}: {reply.stderr}; {WORK}")
            return reply.stdout.strip()

        def state():
            return json.loads(call("screenshot", "status"))

        def screen_state():
            return json.loads(call("screenshottest", "screenState"))

        def screenshot_layers():
            found = []
            def visit(value):
                if isinstance(value, dict):
                    if value.get("namespace") in ("quickshell-de:screenshot", "quickshell-de:screenshot-capture"):
                        found.append(value["namespace"])
                    for item in value.values():
                        visit(item)
                elif isinstance(value, list):
                    for item in value:
                        visit(item)
            visit(json.loads(command("j/layers")))
            return found

        def closed():
            wait_until(lambda: not state()["active"], "Screenshot idle")
            wait_until(lambda: not screenshot_layers(), "Screenshot layer teardown")
            wait_until(lambda: not CAPTURE_BASE.exists() or not list(CAPTURE_BASE.glob("capture-*")), "Private screenshot cleanup", 14)
            assert call("screenshottest", "directory") == ""

        def open_capture(mode="monitor"):
            assert call("screenshot", mode) == "true"
            current = wait_until(lambda: (value if (value := state())["phase"] == "selecting" else None), "Native capture")
            assert not current["errorMessage"], current
            wait_until(lambda: screenshot_layers().count("quickshell-de:screenshot") == len(current["screens"]), "Overlay mapping")
            wait_until(lambda: "quickshell-de:screenshot-capture" not in screenshot_layers(), "Capture buffer teardown", 3)
            return current

        def records():
            return {item["name"]: item for item in json.loads(call("screenshottest", "records"))}

        def source_data(record):
            assert call("screenshottest", "directory") == "", "Storage created before an export action"
            assert not CAPTURE_BASE.exists() or not list(CAPTURE_BASE.glob("capture-*"))
            path = WORK / record["basename"]
            assert call("screenshottest", "reference", record["name"], path) == "true"
            return path.read_bytes()

        wait_until(lambda: len(screen_state()) == 2, "Screenshot fixture startup")
        time.sleep(.4)
        call("screenshottest", "setDirectory", WORK / "saved")
        SUMMARY["cold"] = measure(shell)
        current = open_capture()
        initial_records = records()
        expected_dimensions = {"SCREENSHOT-A": (1280, 720), "SCREENSHOT-B": (1440, 900)}
        for name, dimensions in expected_dimensions.items():
            record = initial_records[name]
            data = source_data(record)
            assert png_size(data) == dimensions
            assert (record["pixelWidth"], record["pixelHeight"]) == dimensions
            raw = rgba(data)
            background = bytes((30, 80, 120, 255) if name == "SCREENSHOT-A" else (80, 30, 110, 255))
            assert raw[-4:] == background, (name, raw[-4:])
            assert raw[:4] == bytes((170, 40, 60, 255)), (name, raw[:4])
        assert initial_records["SCREENSHOT-A"]["width"] == 1280
        assert initial_records["SCREENSHOT-B"]["width"] == 1200
        assert call("screenshottest", "monitor", "SCREENSHOT-B") == "true"
        assert state()["selection"]["screenName"] == "SCREENSHOT-B"
        assert state()["screenName"] == "SCREENSHOT-B"
        call("screenshot", "cancel")
        closed()
        SUMMARY["checks"].append("Two native PNG frames exactly 1280x720 and 1440x900 at scales 1 and 1.2; synthetic source pixels; monitor switch")

        for name, dimensions in expected_dimensions.items():
            open_capture()
            reference = source_data(records()[name])
            assert call("screenshottest", "monitor", name) == "true"
            assert call("screenshottest", "perform", "save") == "true"
            closed()
            saved = Path(state()["lastSavedPath"])
            assert saved.is_relative_to(WORK / "saved") and saved.stat().st_mode & 0o777 == 0o600
            assert png_size(saved.read_bytes()) == dimensions
            assert rgba(saved.read_bytes()) == rgba(reference)
        SUMMARY["checks"].append("Real save on both monitors preserves every source pixel and physical dimensions; unique private PNG files")

        # The expected byte rectangle is sliced from the full native frame,
        # independently of ImageMagick's crop implementation.
        open_capture("open")
        record = records()["SCREENSHOT-B"]
        reference = source_data(record)
        expected_pixels = raw_crop(rgba(reference), 1440, 15, 20, 122, 96)
        assert call("screenshottest", "select", "SCREENSHOT-B", 13, 17, 101, 79) == "true"
        assert call("screenshottest", "perform", "copy") == "true"
        closed()
        clipboard = subprocess.run(["wl-paste", "--type", "image/png", "--no-newline"], env=env,
                                   capture_output=True, timeout=5, check=True).stdout
        assert png_size(clipboard) == (122, 96)
        assert rgba(clipboard) == expected_pixels
        (WORK / "copied-region.png").write_bytes(clipboard)
        SUMMARY["clipboard_sha256"] = hashlib.sha256(clipboard).hexdigest()
        SUMMARY["checks"].append("Real crop and private wl-copy to wl-paste: 122x96 PNG, all decoded bytes match native source rectangle")

        def reconfigure(scale=1.2, transform=0):
            write_config(scale, transform)
            assert command("reload config-only").strip() == "ok"
            wait_until(lambda: any(item["name"] == "SCREENSHOT-B" and item["scale"] == scale
                       and item["transform"] == transform for item in monitors()), "Monitor rule application")

        open_capture()
        reconfigure(scale=1.5)
        closed()
        assert state()["errorMessage"], "Scale change should explain cancellation"
        reconfigure()
        wait_until(lambda: any(item["name"] == "SCREENSHOT-B" and item["width"] == 1200 for item in screen_state()), "Scale reset")
        open_capture()
        reconfigure(transform=2)
        closed()
        assert state()["errorMessage"], "180-degree rotation should cancel even when dimensions do not change"
        open_capture()
        rotated = source_data(records()["SCREENSHOT-B"])
        assert png_size(rotated) == (1440, 900)
        rotated_pixels = rgba(rotated)
        assert rotated_pixels[:4] == bytes((170, 40, 60, 255))
        assert rotated_pixels[-4:] == bytes((80, 30, 110, 255))
        SUMMARY["checks"].append("New native frame after 180-degree rotation retains correct orientation and physical PNG dimensions")
        reconfigure()
        closed()
        time.sleep(.3)
        open_capture()
        assert command("output remove SCREENSHOT-B").strip() == "ok"
        closed()
        assert state()["errorMessage"], "Output removal should explain cancellation"
        wait_until(lambda: len(screen_state()) == 1, "Output removal propagation")
        open_capture()
        assert command("output create headless SCREENSHOT-B").strip() == "ok"
        closed()
        assert state()["errorMessage"], "Output addition should explain cancellation"
        wait_until(lambda: len(screen_state()) == 2, "Hotplug recovery")
        open_capture()
        call("screenshot", "cancel")
        closed()
        SUMMARY["checks"].append("Scale change, 180-degree rotation and hotplug cancel active capture, clean files/layers, and allow recovery")

        if "--panels" in sys.argv:
            # Compare stable desktop pixels below the bar. A closing panel must
            # be absent from the frozen frame, including during its animation.
            for panel in ("quickSettings", "notifications", "launcher"):
                call("surfaces", "open", panel)
                time.sleep(.3)
                open_capture()
                assert call("surfaces", "active") == ""
                record = records()["SCREENSHOT-A"]
                raw = rgba(source_data(record))
                # Right below the full bar footprint, in the deterministic background.
                for x, y in ((1150, 180), (1180, 250), (1150, 350)):
                    offset = (y * 1280 + x) * 4
                    assert raw[offset:offset+4] == bytes((30, 80, 120, 255)), (panel, x, y, raw[offset:offset+4])
                call("screenshot", "cancel")
                closed()
            SUMMARY["checks"].append("Actual bar panels close before capture; frozen desktop pixels contain no quick settings, notifications or launcher")
        SUMMARY["before_cycles"] = measure(shell)
        cycle_memory = []
        for series in range(2):
            for cycle in range(2 if "--panels" in sys.argv else 20):
                open_capture("open" if cycle % 2 else "monitor")
                call("screenshot", "cancel")
                closed()
                fields = (Path("/proc") / str(shell.pid) / "stat").read_text().rsplit(")", 1)[1].split()
                cycle_memory.append(int(fields[21]) * os.sysconf("SC_PAGE_SIZE") // 1024)
            SUMMARY["after_first_cycles" if series == 0 else "after_cycles"] = measure(shell)
        SUMMARY["rss_per_cycle_kib"] = cycle_memory
        SUMMARY["checks"].append("Two series of real IPC open/monitor/cancel cycles; no surviving capture/overlay layers or private session directories")
        errors = re.findall(r"^.*(?:WARN |TypeError:|ReferenceError:|Binding loop|Cannot assign|Unable to assign).*$",
                            (WORK / "shell.log").read_text(), re.MULTILINE)
        errors = [line for line in errors if "qt.qpa.services: Failed to register with host portal" not in line]
        assert not errors, {"qml_errors": errors, "evidence": str(WORK)}
        assert production_state(parent_socket) == before, "Production monitors or mapped nested windows changed"
        SUMMARY["production_unchanged"] = True
        SUMMARY["passed"] = True
    finally:
        if shell and shell.poll() is None:
            with suppress(Exception):
                SUMMARY["final_status"] = state()
                SUMMARY["final_screens"] = screen_state()
                SUMMARY["final_monitors"] = [{key: monitor[key] for key in ("name", "width", "height", "scale", "transform")}
                                             for monitor in monitors()]
        stop(shell)
        stop(compositor)
        stop(bus)
        for stream in log_files:
            stream.close()
        with suppress(OSError, ValueError):
            SUMMARY["production_unchanged_after_teardown"] = production_state(parent_socket) == before
        (WORK / "result.json").write_text(json.dumps(SUMMARY, indent=2))
        print(json.dumps(SUMMARY, indent=2))
        print("Evidence:", WORK, flush=True)


if __name__ == "__main__":
    run()
