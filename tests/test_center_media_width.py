#!/usr/bin/env python3
"""Check native media source, bounded geometry and functional overflow scrolling."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

if os.environ.get("QS_CENTER_MEDIA_PRIVATE_BUS") != "1":
    with tempfile.TemporaryDirectory(prefix="quickshell-center-media-bus-") as directory:
        conf = Path(directory) / "bus.conf"
        conf.write_text('''<busconfig><type>session</type><listen>unix:tmpdir=/tmp</listen>
<policy context="default"><allow send_destination="*"/><allow receive_sender="*"/>
<allow own="*"/></policy></busconfig>''')
        raise SystemExit(subprocess.call(["dbus-run-session", "--config-file", str(conf),
            "--", sys.executable, __file__], env=dict(os.environ, QS_CENTER_MEDIA_PRIVATE_BUS="1")))

import dbus

root = Path(__file__).resolve().parents[1]
work = Path(tempfile.mkdtemp(prefix="quickshell-center-media-width-"))
config = work / "shell"
shutil.copytree(root, config, ignore=shutil.ignore_patterns("inspirations", "__pycache__"))
if os.environ.get("QS_CENTER_MEDIA_BASELINE"):
    baseline = Path(os.environ["QS_CENTER_MEDIA_BASELINE"])
    for name in ("MediaPopup.qml", "MediaModule.qml", "BarIsland.qml"):
        relative = Path("popups" if name == "MediaPopup.qml" else "modules/statusbar") / name
        source = baseline / relative
        if not source.exists(): source = baseline / name
        if source.exists():
            shutil.copy2(source, config / ("popups" if name == "MediaPopup.qml" else "modules/statusbar") / name)
shutil.copy2(config / "tests/fixtures/center-media-width.qml", config / "shell.qml")
(config / "services/HyprlandService.qml").write_text('''pragma Singleton
import Quickshell
Singleton {
    property string testTitle: "sh"
    readonly property var fixtureWindow: ({address: "test", title: testTitle})
    function screenName(screen) { return "center-media-test"; }
    function activeToplevelFor(screen) { return fixtureWindow; }
    function activeWorkspace(screen) { return {id: 1}; }
    function contextApplicationId(window) { return ""; }
    function toplevelClass(window) { return "kitty"; }
    function isTerminal(window) { return true; }
    function isBrowser(window) { return false; }
    function displayTitleFor(screen) { return testTitle; }
    function terminalHostFor(screen) { return "pc"; }
    function terminalCommandFor(screen) { return "fish"; }
}
''')
# Reuse the native MPRIS provider; changing only its synthetic artist keeps
# these geometry checks independent of any real browser or media session.
provider = config / "tests/test_media.py"
# Exercise the trusted browser bridge metadata contract on the private bus;
# the copied provider emits synthetic fields and never connects to a browser.
provider.write_text(provider.read_text().replace('"org.mpris.MediaPlayer2.test_" + identity.lower()',
    '"org.mpris.MediaPlayer2.quickshell_browser." + identity.lower()'))
runtime = work / "runtime"
runtime.mkdir(mode=0o700)
env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_QPA_PLATFORMTHEME="", NO_AT_BRIDGE="1",
    WAYLAND_DISPLAY="", HYPRLAND_INSTANCE_SIGNATURE="", DBUS_SYSTEM_BUS_ADDRESS=os.environ["DBUS_SESSION_BUS_ADDRESS"],
    XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(work / "config"), XDG_STATE_HOME=str(work / "state"),
    XDG_CACHE_HOME=str(work / "cache"))
bus = dbus.SessionBus()
with (work / "shell.log").open("w") as log:
    proc = subprocess.Popen(["qs", "-p", str(config), "--no-color"], env=env, stdout=log, stderr=log)
    player = subprocess.Popen([sys.executable, str(provider), "--player", "Geometry"], env=env, stdout=log, stderr=log)
    def ipc(method, *args):
        result = subprocess.run(["qs", "ipc", "--pid", str(proc.pid), "call", "centermediawidthtest", method, *args],
            env=env, text=True, capture_output=True, timeout=5)
        assert result.returncode == 0, (result.stderr, str(work))
        return result.stdout.strip()
    def validate(row, *, limited=False):
        assert row["expanded"] and row["panelVisible"] and row["panelOpacity"] == 1, row
        assert row["islandHeight"] == row["height"] + 40, row
        assert row["island"] <= min(560, row["capacity"]), row
        assert row["loader"] == row["panel"] == row["island"] - 8, row
        for name in ("title", "artist", "album", "source"):
            field = row[name]
            assert field["textMatches"] and field["format"] == 0, {"field": name, **field}
            assert field["offset"] == 0 and not field["scrolling"], {"field": name, **field}
        for child in row["children"]:
            assert child["x"] >= -1 and child["y"] >= -1 \
                and child["x"] + child["width"] <= row["panel"] + 1 \
                and child["y"] + child["height"] <= row["height"] + 1, {"overflow": child, "logs": str(work)}
        controls = {c["name"]: c for c in row["children"] if c["name"] in ("mediaPrevious", "mediaPlayPause", "mediaNext")}
        assert [controls[k]["width"] for k in ("mediaPrevious", "mediaPlayPause", "mediaNext")] == [42, 48, 42], controls
        artwork = next(c for c in row["children"] if c["name"] == "mediaArtwork")
        assert artwork["width"] == artwork["height"] == 104, artwork
        assert row["source"]["y"] + row["source"]["height"] < artwork["y"], row
        if not row["source"]["overflow"]:
            source = row["source"]
            assert abs(source["textX"] + source["textWidth"] / 2 - source["width"] / 2) < 1, source
    try:
        deadline = time.monotonic() + 10
        while not bus.name_has_owner("org.mpris.MediaPlayer2.quickshell_browser.geometry"):
            assert player.poll() is None and time.monotonic() < deadline, str(work)
            time.sleep(.05)
        control = dbus.Interface(bus.get_object("org.mpris.MediaPlayer2.quickshell_browser.geometry", "/org/mpris/MediaPlayer2"), "org.test.Media")
        control.Configure(json.dumps({"title": "An intentionally long episode title — Season 04 Episode 02 — The night train",
            "kind": "video", "state": "Paused", "art": "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='104' height='104'%3E%3Crect width='104' height='104' fill='white'/%3E%3C/svg%3E"}))
        control.Configure(json.dumps({"metadata": {
            "xesam:artist": ["A long performing artist name with orchestra and featured musicians"],
            "xesam:album": "An extended album name — The complete collection of live recordings and bonus tracks"}}))
        while True:
            try:
                if ipc("ready") == "true": break
            except AssertionError: pass
            assert proc.poll() is None and time.monotonic() < deadline, str(work)
            time.sleep(.05)
        assert int(ipc("requested")) <= 560, {"widthAboveCap": ipc("requested"), "logs": str(work)}
        rows = []
        for name, title in [("short", "sh"), ("long", "/work/same-media-longer-context")]:
            row = json.loads(ipc("snapshot", title))
            row["afterCapture"] = json.loads(ipc("screenshot", str(work / f"{name}.png")))
            assert row["afterCapture"]["expanded"] and row["afterCapture"]["height"] == row["height"] + 40, row
            rows.append({"case": name, **row})
        (work / "geometry.json").write_text(json.dumps(rows, indent=2))
        for row in rows: validate(row)
        assert rows[0]["island"] == rows[1]["island"], "Identical media depends on window title length"

        assert rows[0]["island"] == 560 and rows[0]["sourceText"] == "Geometry", rows[0]
        assert all(rows[0][name]["overflow"] for name in ("title", "album", "artist")), rows[0]
        # Same complete metadata in clipped scrolling viewports at screen cap.
        ipc("capacity", "500")
        limited = json.loads(ipc("snapshot", "sh"))
        ipc("screenshot", str(work / "screen-limit.png"))
        validate(limited, limited=True)
        assert limited["island"] == 500, limited
        rows.append({"case": "screen-limit", **limited})
        ipc("capacity", "1000")

        control.Configure(json.dumps({"metadata": {"browser:pageTitle": "A reliably supplied synthetic page title with enough words to overflow the complete centered source row"}}))
        time.sleep(.1)
        page = json.loads(ipc("snapshot", "sh"))
        validate(page)
        assert page["source"]["overflow"] and page["sourceText"].startswith("Geometry · "), page
        ipc("screenshot", str(work / "source-page.png"))
        rows.append({"case": "source-page", **page})
        lifecycle = json.loads(ipc("lifecycle"))
        (work / "lifecycle.json").write_text(json.dumps(lifecycle, indent=2))
        assert lifecycle["moving"]["offset"] > 5 and lifecycle["moving"]["scrolling"], lifecycle
        assert lifecycle["sourceReset"]["offset"] == 0 and lifecycle["sourceReset"]["scrolling"], lifecycle
        assert lifecycle["movingAgain"]["offset"] > 5, lifecycle
        for state in ("hidden", "hiddenLater", "reduced"):
            assert lifecycle[state]["offset"] == 0 and not lifecycle[state]["scrolling"], lifecycle
        assert lifecycle["shown"]["offset"] == 0 and lifecycle["shown"]["scrolling"], lifecycle
        assert lifecycle["manualEnd"]["offset"] > 100 and not lifecycle["manualEnd"]["scrolling"], lifecycle
        assert lifecycle["manualHome"]["offset"] == 0, lifecycle
        assert lifecycle["tooltipMatches"] and lifecycle["escaped"] and lifecycle["released"], lifecycle
        control.Configure(json.dumps({"metadata": {"browser:pageTitle": None}}))
        time.sleep(.1)
        ipc("snapshot", "sh")
        def memory():
            status = Path(f"/proc/{proc.pid}/status").read_text()
            return int(re.search(r"^VmRSS:\s+(\d+)", status, re.MULTILINE).group(1))
        cycles = {"beforeRssKiB": memory(), "count": 20}
        for _ in range(20):
            assert ipc("cycle") == "true", "Closed panel retained its loader or did not animate overflow"
        cycles["afterRssKiB"] = memory()
        (work / "cycles.json").write_text(json.dumps(cycles, indent=2))
        ipc("snapshot", "sh")
        transitions = []
        for cycle in range(1):
            transitions.append(json.loads(ipc("transition")))
        for step in transitions:
            assert any(step["start"] < width < step["final"] for width in step["widths"]), step
            assert all(step["start"] <= width <= step["final"] for width in step["widths"]), step
        # Configure another track while the panel stays open. snapshot() does
        # not change the surface identity, so this exercises the host signal.
        control.Configure(json.dumps({"title": "A short title <live> & literal text", "kind": "video", "state": "Paused",
            "art": "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='104' height='104'%3E%3Crect width='104' height='104' fill='white'/%3E%3C/svg%3E"}))
        control.Configure(json.dumps({"metadata": {"xesam:artist": ["Test artist"], "xesam:album": ""}}))
        time.sleep(.25)
        updated = json.loads(ipc("snapshot", "sh"))
        validate(updated)
        assert updated["island"] < rows[0]["island"], "Metadata change did not resize the open panel"
        assert not updated["title"]["overflow"], updated
        control.Configure(json.dumps({"title": "Song", "kind": "audio", "state": "Paused"}))
        time.sleep(.25)
        minimum = json.loads(ipc("snapshot", "sh"))
        validate(minimum)
        assert minimum["island"] == 430 and not minimum["title"]["overflow"], minimum
        rows.append({"case": "minimum", **minimum})
        assert updated["title"]["format"] == 0, "MPRIS metadata is not rendered as plain text"
        rows.append({"case": "metadata-update", **updated})
        (work / "geometry.json").write_text(json.dumps(rows, indent=2))
        (work / "transitions.json").write_text(json.dumps(transitions, indent=2))
        errors = re.findall(r"^.*(?:WARN scene|TypeError:|ReferenceError:|Binding loop).*$", (work / "shell.log").read_text(), re.MULTILINE)
        assert not errors, {"logs": str(work), "errors": errors}
        print("PASS: native source, optional page, 430–560 px bounds, 500 px screen limit,")
        print("title/album/artist overflow, automatic scroll, source/hide/reduced resets, keyboard, tooltip, Escape and metadata resize.")
        print(f"Geometry and screenshots: {work}")
    finally:
        for child in (player, proc):
            child.terminate()
            try: child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill(); child.wait(timeout=3)
