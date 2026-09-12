#!/usr/bin/env python3
"""Real Quickshell MPRIS + panel on a private D-Bus; synthetic audio/video only."""
import ctypes
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import struct
import sys
import tempfile
import time


def fake_player(identity):
    import dbus
    import dbus.service
    from dbus.mainloop.glib import DBusGMainLoop
    DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    name = dbus.service.BusName("org.mpris.MediaPlayer2.test_" + identity.lower(), bus)
    interface = "org.mpris.MediaPlayer2.Player"

    class Player(dbus.service.Object):
        def __init__(self):
            super().__init__(bus, "/org/mpris/MediaPlayer2")
            self.position = 0
            self.position_available = os.environ.get("QS_TEST_POSITION_SUPPORTED", "1") == "1"
            self.started = time.monotonic()
            self.calls = []
            self.base = {"CanQuit": False, "CanRaise": False, "HasTrackList": False,
                "Identity": identity, "DesktopEntry": "media-test", "SupportedUriSchemes": dbus.Array(["file"], signature="s"),
                "SupportedMimeTypes": dbus.Array(["audio/ogg", "video/mp4"], signature="s")}
            self.props = {"PlaybackStatus": os.environ.get("QS_TEST_INITIAL_STATE", "Stopped"), "Metadata": self.metadata("Test audio", "audio"),
                "CanControl": True, "CanGoNext": True, "CanGoPrevious": True, "CanPlay": True,
                "CanPause": True, "CanSeek": True, "Rate": 1., "MinimumRate": 1., "MaximumRate": 1.,
                "Volume": 1., "LoopStatus": "None", "Shuffle": False}

        def metadata(self, title, kind, length=True, art=""):
            value = {"mpris:trackid": dbus.ObjectPath("/test/" + kind), "xesam:title": title,
                "xesam:artist": dbus.Array(["Test artist"], signature="s"),
                "xesam:url": "file:///synthetic." + ("mp4" if kind == "video" else "ogg"), "mpris:artUrl": art}
            if length:
                value["mpris:length"] = dbus.Int64(120000000)
            return dbus.Dictionary(value, signature="sv")

        @dbus.service.method("org.freedesktop.DBus.Properties", in_signature="s", out_signature="a{sv}")
        def GetAll(self, requested):
            if requested == "org.mpris.MediaPlayer2":
                return self.base
            return dict(self.props, Position=self.Get(interface, "Position")) if self.position_available else self.props

        @dbus.service.method("org.freedesktop.DBus.Properties", in_signature="ss", out_signature="v")
        def Get(self, requested, key):
            if requested == "org.mpris.MediaPlayer2":
                return self.base[key]
            if key == "Position":
                if not self.position_available:
                    raise dbus.exceptions.DBusException("Position unavailable", name="org.freedesktop.DBus.Error.InvalidArgs")
                elapsed = time.monotonic() - self.started if self.props["PlaybackStatus"] == "Playing" else 0
                return dbus.Int64(self.position + elapsed * 1000000)
            return self.props[key]

        @dbus.service.method("org.freedesktop.DBus.Properties", in_signature="ssv", out_signature="")
        def Set(self, requested, key, value):
            self.props[key] = value
            self.PropertiesChanged(interface, {key: value}, [])

        @dbus.service.signal("org.freedesktop.DBus.Properties", signature="sa{sv}as")
        def PropertiesChanged(self, requested, changed, invalidated): pass

        @dbus.service.signal(interface, signature="x")
        def Seeked(self, position): pass

        @dbus.service.method("org.test.Media", in_signature="s", out_signature="")
        def Configure(self, encoded):
            options = json.loads(encoded)
            changed = {}
            if "desktopEntry" in options:
                self.base["DesktopEntry"] = options["desktopEntry"]
                self.PropertiesChanged("org.mpris.MediaPlayer2", {"DesktopEntry": options["desktopEntry"]}, [])
            if "state" in options:
                if self.position_available:
                    self.position = int(self.Get(interface, "Position"))
                self.started = time.monotonic()
                changed["PlaybackStatus"] = options["state"]
            if "title" in options:
                changed["Metadata"] = self.metadata(options["title"], options.get("kind", "audio"),
                    options.get("length", True), options.get("art", ""))
            if "metadata" in options:
                metadata = dict(self.props["Metadata"])
                for key, value in options["metadata"].items():
                    if value is None:
                        metadata.pop(key, None)
                    else:
                        if key == "mpris:length": value = dbus.Int64(value)
                        elif key == "mpris:trackid": value = dbus.ObjectPath(value)
                        elif key == "xesam:artist": value = dbus.Array(value, signature="s")
                        metadata[key] = value
                changed["Metadata"] = dbus.Dictionary(metadata, signature="sv")
            if "positionSupported" in options:
                self.position_available = options["positionSupported"]
                if self.position_available:
                    changed["Position"] = self.Get(interface, "Position")
            for key in ("CanControl", "CanGoNext", "CanGoPrevious", "CanPlay", "CanPause", "CanSeek"):
                if key in options:
                    changed[key] = options[key]
            self.props.update(changed)
            self.PropertiesChanged(interface, changed, [])

        @dbus.service.method("org.test.Media", out_signature="s")
        def Calls(self): return json.dumps(self.calls)

        def change_playback(self, state, method):
            self.calls.append(method)
            self.Configure(json.dumps({"state": state}))

        @dbus.service.method(interface)
        def Play(self): self.change_playback("Playing", "Play")
        @dbus.service.method(interface)
        def Pause(self): self.change_playback("Paused", "Pause")
        @dbus.service.method(interface)
        def PlayPause(self): self.change_playback("Paused" if self.props["PlaybackStatus"] == "Playing" else "Playing", "PlayPause")
        @dbus.service.method(interface)
        def Previous(self): self.calls.append("Previous")
        @dbus.service.method(interface)
        def Next(self): self.calls.append("Next")
        @dbus.service.method(interface, in_signature="ox")
        def SetPosition(self, track, position):
            self.calls.append("SetPosition")
            self.position = int(position)
            self.started = time.monotonic()
            self.Seeked(position)

    player = Player()
    glib = ctypes.CDLL("libglib-2.0.so.0")
    glib.g_main_loop_new.argtypes = [ctypes.c_void_p, ctypes.c_int]
    glib.g_main_loop_new.restype = ctypes.c_void_p
    glib.g_main_loop_run.argtypes = [ctypes.c_void_p]
    glib.g_main_loop_run(glib.g_main_loop_new(None, False))


if "--player" in sys.argv:
    fake_player(sys.argv[-1])
    raise SystemExit(0)

if os.environ.get("QS_MEDIA_PRIVATE_BUS") != "1":
    with tempfile.TemporaryDirectory(prefix="quickshell-media-bus-") as directory:
        conf = Path(directory) / "bus.conf"
        conf.write_text('''<busconfig><type>session</type><listen>unix:tmpdir=/tmp</listen>
<policy context="default"><allow send_destination="*"/><allow receive_sender="*"/>
<allow own="*"/></policy></busconfig>''')
        raise SystemExit(subprocess.call(["dbus-run-session", "--config-file", str(conf), "--", sys.executable, __file__],
            env=dict(os.environ, QS_MEDIA_PRIVATE_BUS="1")))

import dbus
root = Path(__file__).resolve().parents[1]
work = Path(tempfile.mkdtemp(prefix="quickshell-media-"))
config = work / "shell"
shutil.copytree(root, config)
if os.environ.get("QS_MEDIA_BASELINE"):
    baseline = Path(os.environ["QS_MEDIA_BASELINE"])
    # Test the previous service independently, keeping new UI's introspection API.
    shutil.copy2(baseline / "services/MediaService.qml", config / "services/MediaService.qml")
shutil.copy2(config / "tests/fixtures/media.qml", config / "shell.qml")
(config / "services/HyprlandService.qml").write_text('''pragma Singleton
import Quickshell
Singleton { function screenName(screen) { return "media-test"; } }
''')
runtime = work / "runtime"
runtime.mkdir(mode=0o700)
env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_QPA_PLATFORMTHEME="", NO_AT_BRIDGE="1",
    WAYLAND_DISPLAY="", HYPRLAND_INSTANCE_SIGNATURE="", DBUS_SYSTEM_BUS_ADDRESS=os.environ["DBUS_SESSION_BUS_ADDRESS"],
    XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(work / "config"), XDG_STATE_HOME=str(work / "state"),
    XDG_CACHE_HOME=str(work / "cache"))
bus = dbus.SessionBus()
children = []
latencies = []

with (work / "shell.log").open("w") as log:
    proc = subprocess.Popen(["qs", "-p", str(config), "--no-color"], env=env, stdout=log, stderr=log)
    children.append(proc)

    def ipc(method, *args):
        result = subprocess.run(["qs", "ipc", "--pid", str(proc.pid), "call", "mediatest", method, *map(str, args)],
            env=env, capture_output=True, text=True, timeout=5)
        assert result.returncode == 0, (result.stderr, str(work))
        return result.stdout.strip()

    def snapshot(): return json.loads(ipc("snapshot"))

    def expect(**expected):
        start = time.monotonic()
        while time.monotonic() - start < 3:
            state = snapshot()
            if all(state.get(key) == value for key, value in expected.items()):
                latencies.append(round((time.monotonic() - start) * 1000, 1))
                return state
            time.sleep(.025)
        raise AssertionError({"expected": expected, "actual": state, "logs": str(work)})

    def start_player(identity, initial_state="Stopped", position_supported=True):
        child = subprocess.Popen([sys.executable, __file__, "--player", identity],
            env=dict(env, QS_TEST_INITIAL_STATE=initial_state,
                QS_TEST_POSITION_SUPPORTED="1" if position_supported else "0"), stdout=log, stderr=log)
        children.append(child)
        name = "org.mpris.MediaPlayer2.test_" + identity.lower()
        deadline = time.monotonic() + 5
        while not bus.name_has_owner(name):
            assert child.poll() is None and time.monotonic() < deadline, str(work)
            time.sleep(.025)
        control = dbus.Interface(bus.get_object(name, "/org/mpris/MediaPlayer2"), "org.test.Media")
        return child, control

    def configure(control, **values): control.Configure(json.dumps(values))

    def measure(seconds=1):
        def stat():
            fields = Path(f"/proc/{proc.pid}/stat").read_text().split()
            return int(fields[13]) + int(fields[14])
        before = stat(); time.sleep(seconds)
        rss = int(re.search(r"VmRSS:\s+(\d+)", Path(f"/proc/{proc.pid}/status").read_text())[1])
        return {"cpuPercent": round((stat()-before) / os.sysconf("SC_CLK_TCK") / seconds * 100, 2), "rssKiB": rss}

    try:
        deadline = time.monotonic() + 10
        while True:
            try: state = snapshot(); break
            except (AssertionError, json.JSONDecodeError):
                assert proc.poll() is None and time.monotonic() < deadline, str(work)
                time.sleep(.05)
        expect(count=0, active=None, timer=False)
        white, mauve = state["white"], state["mauve"]
        if os.environ.get("QS_MEDIA_BRIDGE_ONLY") == "1":
            host = subprocess.Popen([sys.executable, str(root / "integrations/browser-media/host/browser_media_host.py")],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, env=env)
            children.append(host)
            sample = {"type": "update", "tabId": 7, "sourceHost": "music.apple.com",
                "pageTitle": "Synthetic source page", "title": "Synthetic song", "artist": "Synthetic artist",
                "album": "Synthetic album", "duration": 120, "position": 10, "playbackRate": 1,
                "state": "Paused", "canSeek": True, "canPlay": True, "canPause": True}
            def bridge_update(**changes):
                data = json.dumps(dict(sample, **changes)).encode()
                host.stdin.write(struct.pack("=I", len(data)) + data); host.stdin.flush()
            bridge_update()
            expect(count=1, active="Zen Browser", sourceName="Zen Browser", sourcePageTitle="Synthetic source page",
                title="Synthetic song", album="Synthetic album", hasTimeline=True, timelineDuration=120,
                nativePosition=10, progressVisible=True, canSeekTimeline=True)
            bridge_update(position=None)
            expect(timelineDurationPending=True)
            expect(hasTimeline=False, progressVisible=False)
            bridge_update(position=25, pageTitle="Updated source page")
            expect(hasTimeline=True, progressVisible=True, nativePosition=25, sourcePageTitle="Updated source page")
            bridge_update(state="Playing", position=26)
            expect(playing=True, timer=True, foreground=mauve)
            bridge_update(state="Paused", position=27)
            expect(playing=False, timer=False, foreground=white)
            ipc("screenshot", str(work / "browser-bridge.png"))
            a_proc, a = start_player("Alpha", "Paused")
            configure(a, desktopEntry="zen", metadata={"xesam:url": "https://music.apple.com/synthetic?private=test",
                "xesam:title": sample["title"], "xesam:artist": [sample["artist"]], "xesam:album": sample["album"],
                "browser:pageTitle": "Untrusted synthetic value"})
            expect(rawCount=2, count=1, active="Zen Browser")
            configure(a, state="Playing")
            expect(count=2, active="Alpha", playing=True, foreground=mauve)
            bridge_update(state="Playing")
            expect(count=1, active="Zen Browser", playing=True)
            configure(a, state="Paused")
            expect(count=2, active="Zen Browser", playing=True)
            bridge_update(state="Paused")
            expect(count=1, playing=False, foreground=white)
            configure(a, metadata={"xesam:artist": ["Different artist"]})
            expect(count=2)
            ipc("select", "Alpha")
            expect(active="Alpha", sourcePageTitle="")
            configure(a, metadata={"xesam:artist": [sample["artist"]]})
            expect(count=2, active="Alpha", selected="Alpha")
            ipc("select", "")
            expect(count=1, active="Zen Browser")
            bridge_update(tabId=8, sourceHost="soundcloud.com", pageTitle="Synthetic SoundCloud page")
            expect(count=2, rawCount=3)
            labels = snapshot()["playerLabels"]
            assert "Zen Browser · Synthetic source page" in labels
            assert "Zen Browser · Synthetic SoundCloud page" in labels
            chosen_label = "Zen Browser · Synthetic SoundCloud page"
            ipc("selectLabel", chosen_label)
            expect(selectorText=chosen_label, sourcePageTitle="Synthetic SoundCloud page")
            details = json.loads(ipc("selectorDetails"))
            assert all(details[key] == chosen_label for key in ("text", "tooltip", "option", "optionTooltip")), details
            assert all(details[key] == 0 for key in ("textFormat", "tooltipFormat", "optionFormat", "optionTooltipFormat")), details
            assert details["optionTooltipVisible"], details
            ipc("select", "")
            b_proc, b = start_player("Beta", "Paused")
            configure(b, desktopEntry="zen", metadata={"xesam:url": "https://soundcloud.com/synthetic",
                "xesam:title": sample["title"], "xesam:artist": [sample["artist"]], "xesam:album": sample["album"]})
            expect(count=2, rawCount=4)
            bridge_update(tabId=9)
            expect(count=4, rawCount=5)
            host.stdin.close(); host.wait(timeout=3)
            expect(count=2, rawCount=2, sourcePageTitle="")
            b_proc.terminate(); b_proc.wait(timeout=3)
            expect(count=1, active="Alpha", sourcePageTitle="", hasTimeline=True)
            a_proc.terminate(); a_proc.wait(timeout=3)
            expect(count=0, active=None, sourcePageTitle="", hasTimeline=False)
            errors = re.findall(r"^.*(?:WARN scene|TypeError:|ReferenceError:|Binding loop).*$", (work / "shell.log").read_text(), re.MULTILINE)
            assert not errors, {"errors": errors, "logs": str(work)}
            result = {"passed": True, "checks": ["real native host -> native Quickshell MPRIS -> actual panel",
                "source page title and album from same tab", "position missing/recovery", "pause/play/icon/timer",
                "unique native/bridge pair dedupe; explicit selection preserved", "same titles on different sites stay independent",
                "card labels distinguish real page titles; anyPlaying includes native owner during bridge delay",
                "ambiguous equal tabs preserved; EOF restores native sources", "untrusted normal-MPRIS page-title ignored", "EOF cleanup"]}
            (work / "bridge.json").write_text(json.dumps(result, indent=2))
            print(json.dumps(result, indent=2)); print(f"Logs: {work}")
            raise SystemExit(0)
        if os.environ.get("QS_MEDIA_TIMELINE_ONLY") == "1":
            timeline_checks = []
            a_proc, a = start_player("Alpha", "Paused")
            expect(active="Alpha", sourceName="Alpha", sourcePageTitle="", album="",
                hasTimeline=True, timelineDuration=120, timelineDurationPending=False)
            before = measure(.5)
            configure(a, metadata={"mpris:length": None})
            expect(hasTimeline=True, timelineDuration=120, timelineDurationPending=True,
                nativeDurationValid=False)
            time.sleep(.15)
            configure(a, metadata={"mpris:length": 120000000})
            expect(hasTimeline=True, timelineDurationPending=False, nativeDurationValid=True)
            timeline_checks.append("same-track missing length restored without hiding")

            started = time.monotonic()
            configure(a, metadata={"mpris:length": None})
            expect(hasTimeline=True, timelineDurationPending=True)
            for _ in range(2):
                time.sleep(.5)
                configure(a, metadata={"mpris:length": None})
                expect(timelineDurationPending=True)
            expect(hasTimeline=False, timelineDuration=-1, timelineDurationPending=False)
            expired_ms = round((time.monotonic() - started) * 1000)
            assert expired_ms < 1900, (expired_ms, str(work))
            timeline_checks.append("repeated missing metadata cannot extend the 1500 ms grace")

            for key, value in (("mpris:trackid", "/test/next"), ("xesam:title", "Next track"),
                    ("xesam:artist", ["Another artist"]), ("xesam:album", "Another album")):
                configure(a, metadata={"mpris:length": 120000000})
                expect(hasTimeline=True)
                configure(a, metadata={"mpris:length": None, key: value})
                expect(hasTimeline=False, timelineDuration=-1, timelineDurationPending=False)
            timeline_checks.append("new track ID/title/artist/album never reuse old duration")

            for duration in (0, -1000000):
                configure(a, metadata={"mpris:length": 120000000})
                expect(hasTimeline=True)
                configure(a, metadata={"mpris:length": duration})
                expect(hasTimeline=False, timelineDuration=-1, timelineDurationPending=False)
            configure(a, metadata={"mpris:length": 120000000, "mpris:trackid": None})
            expect(hasTimeline=True)
            configure(a, metadata={"mpris:length": None})
            expect(hasTimeline=False, timelineDurationPending=False)
            timeline_checks.append("zero/negative duration and unidentifiable tracks do not start grace")

            configure(a, metadata={"mpris:trackid": "/test/alpha", "mpris:length": 120000000})
            expect(hasTimeline=True)
            b_proc, b = start_player("Beta", "Paused", position_supported=False)
            expect(count=2)
            ipc("select", "Beta")
            expect(active="Beta", positionSupported=False, hasTimeline=False, timelineDuration=120)
            configure(b, positionSupported=True)
            expect(positionSupported=True, hasTimeline=True)
            configure(b, CanSeek=False)
            expect(hasTimeline=True, canSeekTimeline=False)
            timeline_checks.append("late Position arrives without restarting source; CanSeek does not hide progress")
            configure(b, metadata={"mpris:length": None})
            expect(timelineDurationPending=True)
            calls_before = json.loads(b.Calls())
            ipc("seekValue", 70)
            assert json.loads(b.Calls()) == calls_before, str(work)
            configure(b, CanSeek=True)
            ipc("seekValue", 999)
            expect(nativePosition=120)
            assert json.loads(b.Calls())[-1] == "SetPosition", str(work)
            timeline_checks.append("grace seeking respects CanSeek and clamps to the known duration")
            ipc("select", "Alpha")
            expect(active="Alpha", timelineDurationPending=False, timelineDuration=120)
            ipc("select", "Beta")
            expect(active="Beta", hasTimeline=False, timelineDuration=-1, timelineDurationPending=False)
            configure(b, metadata={"mpris:length": 240000000})
            expect(hasTimeline=True, timelineDuration=240)
            configure(b, metadata={"mpris:length": None})
            expect(timelineDurationPending=True)
            b_proc.terminate(); b_proc.wait(timeout=3)
            expect(count=1, active="Alpha", timelineDuration=120, timelineDurationPending=False)
            b_proc, b = start_player("Beta", "Paused")
            expect(count=2)
            configure(b, metadata={"mpris:length": None})
            ipc("select", "Beta")
            expect(active="Beta", hasTimeline=False, timelineDuration=-1, timelineDurationPending=False)
            timeline_checks.append("selection changes and owner loss clear the previous source cache")
            after = measure(.5)
            errors = re.findall(r"^.*(?:WARN scene|TypeError:|ReferenceError:|Binding loop).*$", (work / "shell.log").read_text(), re.MULTILINE)
            assert not errors, {"errors": errors, "logs": str(work)}
            result = {"passed": True, "checks": timeline_checks, "graceExpiredMs": expired_ms,
                "before": before, "after": after}
            (work / "timeline.json").write_text(json.dumps(result, indent=2))
            print(json.dumps(result, indent=2)); print(f"Logs: {work}")
            raise SystemExit(0)
        if os.environ.get("QS_MEDIA_RENDER_ONLY") == "1":
            renders = []
            for count, identity in enumerate((None, "Alpha", "Beta")):
                if identity:
                    start_player(identity)
                renders.append(expect(count=count))
                ipc("screenshot", str(work / f"sources-{count}.png"))
            assert all(s["width"] == 430 for s in renders), renders
            errors = re.findall(r"^.*(?:WARN scene|TypeError:|ReferenceError:|Binding loop).*$", (work / "shell.log").read_text(), re.MULTILINE)
            assert not errors, errors
            (work / "render.json").write_text(json.dumps(renders, indent=2))
            print(f"PASS: render 0/1/2 MPRIS sources, common 430 px content; logs: {work}")
            raise SystemExit(0)
        a_proc, a = start_player("Alpha")
        expect(count=1, active="Alpha", playing=False, title="Test audio")
        expect(foreground=white, timer=False)
        configure(a, state="Playing")
        expect(active="Alpha", playing=True, foreground=mauve, timer=True)
        configure(a, state="Stopped")
        expect(active="Alpha", playing=False, foreground=white, timer=False)
        configure(a, state="Playing", title="", kind="video")
        expect(active="Alpha", title="Multimedia bez tytułu", playing=True)
        time.sleep(.15)
        configure(a, title="Test video", kind="video")
        expect(title="Test video", formattedHour="1:01:01")
        b_proc, b = start_player("Beta")
        expect(count=2)
        configure(b, state="Playing", title="Second video", kind="video")
        expect(active="Beta", title="Second video")
        configure(a, title="Late audio metadata")
        expect(active="Beta")
        ipc("select", "Alpha")
        expect(active="Alpha", selected="Alpha", selectorIndex=1)
        configure(a, state="Paused")
        expect(active="Alpha", playing=False, foreground=mauve, timer=False)
        ipc("select", "")
        expect(active="Beta", selected=None, selectorIndex=0)
        ipc("click", "mediaPlayPause")
        expect(playing=False, foreground=white, timer=False)
        ipc("keyboardToggle")
        expect(playing=True, timer=True)
        ipc("click", "mediaPrevious"); ipc("click", "mediaNext"); ipc("seek")
        calls = json.loads(b.Calls())
        assert all(x in calls for x in ("Previous", "Next", "SetPosition")), calls
        assert any(x in calls for x in ("Pause", "PlayPause")), calls
        state = snapshot(); time.sleep(1.1)
        assert snapshot()["ticks"] > state["ticks"], str(work)
        ipc("shown", "false"); expect(timer=False)
        state = snapshot(); time.sleep(1.1)
        assert snapshot()["ticks"] == state["ticks"], str(work)
        ipc("shown", "true"); expect(timer=True)
        configure(b, title="Live video", kind="video", length=False)
        expect(progressVisible=False, timer=False)
        configure(b, CanControl=False)
        expect(canPrevious=False, canNext=False, canPlayPause=False, progressEnabled=False)
        configure(b, CanControl=True, title="Test video", kind="video")
        expect(canPlayPause=True, timer=True)
        configure(b, title="Test artwork", kind="video", art="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='32' height='32'%3E%3Crect width='32' height='32' fill='white'/%3E%3C/svg%3E")
        expect(artworkFallback=False)
        configure(b, title="Test video", kind="video", art="")
        expect(artworkFallback=True)
        ipc("screenshot", str(work / "playing.png"))
        ipc("select", "Beta")
        b_proc.terminate(); b_proc.wait(timeout=3)
        expect(count=1, active="Alpha", selected=None)
        configure(a, state="Playing")
        expect(active="Alpha", playing=True)
        b_proc, b = start_player("Beta", initial_state="Playing")
        expect(count=2, active="Beta", playing=True)
        configure(b, state="Playing", title="Reconnected video", kind="video")
        expect(active="Beta", playing=True)
        configure(b, state="Paused")
        configure(a, state="Paused")
        expect(active="Beta", timer=False, foreground=white)
        ipc("screenshot", str(work / "paused.png"))
        ipc("loaded", "false"); expect(panelLoaded=False)
        before = measure()
        rss = []
        for cycle in range(int(os.environ.get("QS_MEDIA_TEST_CYCLES", "20"))):
            ipc("loaded", "true"); expect(panelLoaded=True, width=430, timer=False)
            ipc("loaded", "false"); expect(panelLoaded=False)
            rss.append(measure(.05)["rssKiB"])
        after = measure()
        a_proc.terminate(); a_proc.wait(timeout=3)
        b_proc.terminate(); b_proc.wait(timeout=3)
        ipc("loaded", "true")
        expect(count=0, active=None, foreground=white, timer=False)
        ipc("screenshot", str(work / "empty.png"))
        errors = re.findall(r"^.*(?:WARN scene|TypeError:|ReferenceError:|Binding loop).*$", (work / "shell.log").read_text(), re.MULTILINE)
        assert not errors, {"errors": errors, "logs": str(work)}
        result = {"passed": True, "cycles": len(rss), "before": before, "after": after, "rss": rss,
            "observationLatencyMsMax": max(latencies), "calls": calls}
        (work / "result.json").write_text(json.dumps(result, indent=2))
        print("PASS: native MPRIS audio/video, stop/pause/resume, late metadata, latest activity, manual/auto selection,")
        print("disconnect/reconnect, capability guards, mouse/keyboard controls, seeking, hidden timer and 20 Loader cycles.")
        print(json.dumps(result)); print(f"Logs: {work}")
    finally:
        for child in reversed(children):
            if child.poll() is None:
                child.terminate()
                try: child.wait(timeout=3)
                except subprocess.TimeoutExpired: child.kill(); child.wait(timeout=3)
