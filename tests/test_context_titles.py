#!/usr/bin/env python3
"""Render actual window context with synthetic Hyprland windows, never private titles."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

if os.environ.get("QS_CONTEXT_TITLE_PRIVATE_BUS") != "1":
    with tempfile.TemporaryDirectory(prefix="quickshell-context-title-bus-") as directory:
        bus = Path(directory) / "bus.conf"
        bus.write_text('''<busconfig><type>session</type><listen>unix:tmpdir=/tmp</listen>
<policy context="default"><allow send_destination="*"/><allow receive_sender="*"/>
<allow own="*"/></policy></busconfig>''')
        raise SystemExit(subprocess.call(["dbus-run-session", "--config-file", str(bus), "--", sys.executable, __file__],
            env=dict(os.environ, QS_CONTEXT_TITLE_PRIVATE_BUS="1")))

root = Path(__file__).resolve().parents[1]
work = Path(tempfile.mkdtemp(prefix="quickshell-context-titles-"))
config = work / "shell"
shutil.copytree(root, config, ignore=shutil.ignore_patterns("inspirations", "__pycache__"))
if os.environ.get("QS_CONTEXT_TITLE_BASELINE"):
    baseline = Path(os.environ["QS_CONTEXT_TITLE_BASELINE"])
    for name in ("services/HyprlandService.qml", "modules/statusbar/ContextModule.qml", "core/Icons.qml", "core/Strings.qml"):
        shutil.copy2(baseline / name, config / name)
shutil.copy2(config / "tests/fixtures/context-titles.qml", config / "shell.qml")
# Replace only the source of windows. Classification, terminal data lookup and
# application title normalization remain the actual production service code.
service = config / "services/HyprlandService.qml"
s = service.read_text().replace('    id: root\n', '    id: root\n    property var fixtureWindow: null\n', 1)
a = s.index('    function activeToplevelFor(screen) {')
b = s.index('    function toplevelClass(toplevel) {', a)
s = s[:a] + '    function activeToplevelFor(screen) { return root.fixtureWindow; }\n\n' + s[b:]
s = s.replace('return screen ? Hyprland.monitorFor(screen) : null;', 'return null;')
service.write_text(s)
runtime = work / "runtime"
runtime.mkdir(mode=0o700)
env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_QPA_PLATFORMTHEME="", NO_AT_BRIDGE="1",
    WAYLAND_DISPLAY="", HYPRLAND_INSTANCE_SIGNATURE="", DBUS_SYSTEM_BUS_ADDRESS=os.environ["DBUS_SESSION_BUS_ADDRESS"],
    XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(work / "config"), XDG_STATE_HOME=str(work / "state"),
    XDG_CACHE_HOME=str(work / "cache"))

with (work / "shell.log").open("w") as log:
    proc = subprocess.Popen(["qs", "-p", str(config), "--no-color"], env=env, stdout=log, stderr=log)
    def ipc(method, *args):
        result = subprocess.run(["qs", "ipc", "--pid", str(proc.pid), "call", "contexttitletest", method, *args],
            env=env, text=True, capture_output=True, timeout=5)
        assert result.returncode == 0, (result.stderr, str(work))
        return result.stdout.strip()
    def measure():
        path = Path(f"/proc/{proc.pid}")
        def ticks():
            data = (path / "stat").read_text().rsplit(")", 1)[1].split()
            return int(data[11]) + int(data[12])
        start = ticks(); now = time.monotonic(); time.sleep(.5)
        return {"cpuPercent": round((ticks() - start) / os.sysconf("SC_CLK_TCK") / (time.monotonic() - now) * 100, 2),
            "rssKiB": int(re.search(r"^VmRSS:\s+(\d+)", (path / "status").read_text(), re.MULTILINE).group(1))}
    try:
        deadline = time.monotonic() + 10
        while True:
            try:
                if ipc("ready") == "true": break
            except AssertionError: pass
            assert proc.poll() is None and time.monotonic() < deadline, str(work)
            time.sleep(.05)
        cases = [
            ("zen", {"windowClass": "zen", "title": "Dokumentacja <Qt> & QML — Zen Browser"}, ["Zen Browser", "·", "Dokumentacja <Qt> & QML"]),
            ("jellyfin", {"windowClass": "com.github.iwalton3.jellyfin-mpv-shim", "title": "Serial · sezon 2 - odcinek 03 - Jellyfin MPV Shim"}, ["Jellyfin", "·", "Serial · sezon 2 - odcinek 03"]),
            ("terminal", {"windowClass": "kitty", "title": "ignored", "host": "test-host", "cwd": "/work/project", "command": "fish"}, ["test-host", "·", "/work/project · fish"]),
            ("terminal-no-host", {"windowClass": "kitty", "title": "⠋ compiling", "command": "codex"}, ["compiling · codex"]),
            ("unknown", {"windowClass": "editor", "title": "Notes - Zen Browser"}, ["Notes - Zen Browser"]),
            ("unknown-empty", {"windowClass": "editor", "title": ""}, ["editor"]),
            ("unknown-missing", {"windowClass": "", "title": ""}, ["Okno"]),
            ("desktop", {"desktop": True, "windowClass": "", "title": ""}, ["Pulpit"]),
        ]
        for window_class, brand, prefix in [("ZEN", "Zen Browser", "Zen Browser"), ("jellyfin-mpv-shim", "Jellyfin MPV Shim", "Jellyfin")]:
            for sep in [" - ", " — ", " – ", " · ", " | "]:
                cases.append(("separator", {"windowClass": window_class, "title": "A - B · C" + sep + brand + sep + brand}, [prefix, "·", "A - B · C" + sep + brand]))
            for title, expected in [(brand, [prefix]), ("", [prefix]), ("   ", [prefix]),
                ("Article about " + brand, [prefix, "·", "Article about " + brand])]:
                cases.append(("empty-or-no-separator", {"windowClass": window_class, "title": title}, expected))
        cases.append(("initial-class", {"windowClass": "", "initialClass": "zen", "title": "Page — Zen Browser"}, ["Zen Browser", "·", "Page"]))
        cases.append(("jellyfin-fallback", {"windowClass": "jellyfin-mpv-shim", "title": "Episode - Jellyfin MPV Shim", "forceFallback": True}, ["Jellyfin", "·", "Episode"]))
        rows = []
        for name, data, expected in cases:
            for reveal in (False, True):
                row = json.loads(ipc("snapshot", json.dumps(dict(data, reveal=reveal))))
                # A brand image replaces the first font glyph only for Jellyfin.
                labels = row["texts"] if row["imageReady"] else row["texts"][1:]
                assert [item["text"] for item in labels] == expected, {"case": name, "expected": expected, "row": row, "logs": str(work)}
                assert all(item["format"] == 0 for item in labels if item["text"] != "·"), row
                assert row["width"] >= row["natural"] and all(item["width"] >= item["natural"] for item in row["texts"]), row
                assert all(item["x"] >= 0 and item["x"] + item["width"] <= row["width"] for item in row["texts"]), row
                assert not any(item["typing"] for item in row["texts"]) and row["expanded"] == reveal, row
                if reveal:
                    assert row["gaps"] == [8, 8] and row["launcherWidth"] > 0 and row["mediaWidth"] > 0, row
                else:
                    assert row["launcherWidth"] == row["mediaWidth"] == 0 and row["island"] == row["width"] + 8, row
                if name == "jellyfin":
                    assert row["imageReady"] and row["imageWidth"] == row["iconToken"], row
                if name == "jellyfin-fallback":
                    assert not row["imageReady"] and row["imageWidth"] == row["iconToken"] and row["texts"][0]["text"] == row["mediaGlyph"], row
                if name in ("zen", "jellyfin", "terminal"):
                    ipc("screenshot", str(work / (name + ("-expanded" if reveal else "") + ".png")))
                rows.append({"case": name, "reveal": reveal, **row})
        # The 20-cycle click/lifecycle test covers window/media/launcher panels;
        # this title test additionally checks stable idle cost after replacements.
        before = measure()
        for _ in range(20):
            ipc("snapshot", json.dumps(dict(cases[0][1], reveal=True)))
            ipc("snapshot", json.dumps(dict(cases[2][1], reveal=False)))
        after = measure()
        errors = re.findall(r"^.*(?:WARN scene|TypeError:|ReferenceError:|Binding loop).*$", (work / "shell.log").read_text(), re.MULTILINE)
        assert not errors, {"errors": errors, "logs": str(work)}
        (work / "result.json").write_text(json.dumps({"passed": True, "cases": len(cases), "cycles": 20,
            "before": before, "after": after, "geometry": rows}, indent=2))
        print(f"PASS: {len(cases)} real service title cases in idle/expanded, Jellyfin icon, full terminal, PlainText, gaps8 and20 replacements.")
        print(json.dumps({"before": before, "after": after})); print(f"Artifacts: {work}")
    finally:
        proc.terminate()
        try: proc.wait(timeout=3)
        except subprocess.TimeoutExpired: proc.kill(); proc.wait(timeout=3)
