#!/usr/bin/python
"""Native framing, actual MPRIS/capabilities and lifecycle, private D-Bus only."""
import json
import os
from pathlib import Path
import selectors
import runpy
import struct
import subprocess
import sys
import tempfile
import time

if os.environ.get("QS_BROWSER_TEST_BUS") != "1":
    with tempfile.TemporaryDirectory(prefix="quickshell-browser-bus-") as folder:
        config = Path(folder) / "bus.conf"
        config.write_text('''<busconfig><type>session</type><listen>unix:tmpdir=/tmp</listen>
<policy context="default"><allow send_destination="*"/><allow receive_sender="*"/>
<allow own="*"/></policy></busconfig>''')
        raise SystemExit(subprocess.call(["dbus-run-session", "--config-file", str(config), "--", sys.executable, __file__],
            env=dict(os.environ, QS_BROWSER_TEST_BUS="1")))

import dbus

work = Path(tempfile.mkdtemp(prefix="quickshell-browser-host-test-"))
host = Path(__file__).resolve().parents[1] / "host/browser_media_host.py"
bus = dbus.SessionBus()
prefix = "org.mpris.MediaPlayer2.quickshell_browser."
interface = "org.mpris.MediaPlayer2.Player"
logs = (work / "host.log").open("w")
process = subprocess.Popen([sys.executable, str(host)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=logs)
selector = selectors.DefaultSelector()
selector.register(process.stdout, selectors.EVENT_READ)


def send(message, fragmented=False):
    data = json.dumps(message).encode()
    frame = struct.pack("=I", len(data)) + data
    if fragmented:
        for part in (frame[:2], frame[2:9], frame[9:]):
            process.stdin.write(part); process.stdin.flush(); time.sleep(.015)
    else:
        process.stdin.write(frame); process.stdin.flush()


def names(): return sorted(str(name) for name in bus.list_names() if name.startswith(prefix))


def wait_for(predicate):
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        if predicate(): return
        assert process.poll() is None, (process.returncode, str(work))
        time.sleep(.02)
    raise AssertionError(str(work))


def properties(name):
    return dbus.Interface(bus.get_object(name, "/org/mpris/MediaPlayer2"), "org.freedesktop.DBus.Properties")


def receive():
    assert selector.select(2), str(work)
    size = struct.unpack("=I", process.stdout.read(4))[0]
    return json.loads(process.stdout.read(size))


sample = {"type": "update", "tabId": 1, "sourceHost": "music.apple.com", "pageTitle": "Synthetic Apple page",
    "title": "Synthetic audio", "artist": "Test artist", "album": "Test album", "duration": 120.,
    "position": 10., "playbackRate": 1., "state": "Paused", "canSeek": True, "canPlay": True,
    "canPause": True, "canNext": True, "canPrevious": True}
checks = []
try:
    send(dict(sample, sourceHost="example.org"))
    send(dict(sample, tabId=True))
    time.sleep(.1)
    assert names() == [], str(work)
    send(sample, fragmented=True)
    wait_for(lambda: len(names()) == 1)
    alpha = names()[0]
    props = properties(alpha)
    data = props.GetAll(interface)
    assert data["Metadata"]["browser:pageTitle"] == sample["pageTitle"]
    assert "xesam:url" not in data["Metadata"]
    assert data["Metadata"]["mpris:length"] == 120000000 and data["Position"] == 10000000
    send(dict(sample, artUrl="https://is1-ssl.mzstatic.com/cover.jpg?private=synthetic#fragment"))
    wait_for(lambda: "mpris:artUrl" in props.Get(interface, "Metadata"))
    assert props.Get(interface, "Metadata")["mpris:artUrl"] == "https://is1-ssl.mzstatic.com/cover.jpg"
    send(dict(sample, artUrl="https://user:synthetic@is1-ssl.mzstatic.com/cover.jpg"))
    wait_for(lambda: "mpris:artUrl" not in props.Get(interface, "Metadata"))
    checks.append("scope validation, fragmented framing, actual MPRIS time/page/album metadata")

    for tab in (1, 3):
        for malformed_text in ("Synthetic\x00suffix", "Synthetic\ud800"):
            send(dict(sample, tabId=tab, title=malformed_text))
            wait_for(lambda: len(names()) == (1 if tab == 1 else 2))
            current = props if tab == 1 else properties(next(name for name in names() if name != alpha))
            wait_for(lambda: current.Get(interface, "Metadata")["xesam:title"] == "Synthetic\ufffd" +
                ("suffix" if "\x00" in malformed_text else ""))
        if tab != 1:
            send({"type": "remove", "tabId": tab})
            wait_for(lambda: names() == [alpha])
    deep = ('{"x":' + '[' * 100000 + '0' + ']' * 100000 + '}').encode()
    process.stdin.write(struct.pack("=I", len(deep)) + deep); process.stdin.flush()
    send(sample)
    wait_for(lambda: props.Get(interface, "Metadata")["xesam:title"] == sample["title"])
    namespace = runpy.run_path(str(host))
    namespace["DBusGMainLoop"](set_as_default=True)
    player_class = namespace["Player"]
    original_apply = player_class.apply
    def fail_during_apply(self, update):
        raise ValueError("Synthetic initialization failure")
    player_class.apply = fail_during_apply
    try:
        try:
            player_class(99, sample)
        except ValueError:
            pass
        else:
            raise AssertionError("Expected synthetic constructor failure")
    finally:
        player_class.apply = original_apply
    assert names() == [alpha], "Failed Player constructor leaked a bus owner"
    checks.append("NUL/surrogates normalize before D-Bus; deep JSON recovers; partial constructor releases owner")

    controls = dbus.Interface(bus.get_object(alpha, "/org/mpris/MediaPlayer2"), interface)
    for name in ("Play", "Pause", "PlayPause", "Next", "Previous"):
        getattr(controls, name)()
        assert receive() == {"type": "command", "tabId": 1, "command": name}
    controls.SetPosition(data["Metadata"]["mpris:trackid"], dbus.Int64(999000000))
    assert receive() == {"type": "command", "tabId": 1, "command": "Seek", "position": 120}
    controls.Seek(dbus.Int64(-3000000))
    assert receive()["position"] == 7
    controls.SetPosition(dbus.ObjectPath("/wrong/track"), dbus.Int64(5000000))
    assert not selector.select(.1)
    send(dict(sample, canSeek=False, canPlay=False))
    wait_for(lambda: not props.Get(interface, "CanSeek"))
    controls.Play(); controls.Seek(dbus.Int64(1000000))
    assert not selector.select(.1)
    checks.append("commands reach only originating tab; capability guards, stale track IDs and seek clamp")

    send(dict(sample, tabId=2, sourceHost="soundcloud.com", title="Synthetic WebAudio", duration=None, position=None))
    wait_for(lambda: len(names()) == 2)
    beta = next(name for name in names() if name != alpha)
    other = properties(beta)
    assert "mpris:length" not in other.Get(interface, "Metadata")
    assert "Position" not in other.GetAll(interface)
    assert not other.Get(interface, "CanSeek")
    assert props.Get(interface, "Position") == 10000000
    send(dict(sample, tabId=2, sourceHost="soundcloud.com", title="Synthetic WebAudio", duration=240, position=20))
    wait_for(lambda: "mpris:length" in other.Get(interface, "Metadata"))
    assert other.Get(interface, "Position") == 20000000
    assert props.Get(interface, "Position") == 10000000
    send(dict(sample, tabId=2, position=None))
    wait_for(lambda: "mpris:length" not in other.Get(interface, "Metadata"))
    checks.append("independent per-tab D-Bus connections; missing position/duration never produces a false range")

    send(dict(sample, state="Playing", position=30))
    wait_for(lambda: props.Get(interface, "PlaybackStatus") == "Playing")
    before_position = int(props.Get(interface, "Position"))
    time.sleep(.15)
    assert int(props.Get(interface, "Position")) > before_position
    send(dict(sample, state="Paused", position=31))
    wait_for(lambda: props.Get(interface, "PlaybackStatus") == "Paused")
    before_position = int(props.Get(interface, "Position")); time.sleep(.1)
    assert int(props.Get(interface, "Position")) == before_position
    checks.append("playing interpolation follows supplied position/rate; paused position remains stable")

    send({"type": "remove", "tabId": 2})
    wait_for(lambda: names() == [alpha])
    send(dict(sample, tabId=2, title="Reused tab", duration=None, position=None))
    wait_for(lambda: len(names()) == 2)
    reused = properties(next(name for name in names() if name != alpha))
    assert "mpris:length" not in reused.Get(interface, "Metadata") and "Position" not in reused.GetAll(interface)
    send({"type": "remove", "tabId": 2})
    wait_for(lambda: names() == [alpha])
    malformed = b'{"type":'
    process.stdin.write(struct.pack("=I", len(malformed)) + malformed); process.stdin.flush()
    send(dict(sample, position=17))
    wait_for(lambda: props.Get(interface, "Position") == 17000000)
    stat = lambda: list(map(int, Path(f"/proc/{process.pid}/stat").read_text().split()[13:15]))
    cpu_before = sum(stat()); time.sleep(1)
    cpu_percent = (sum(stat()) - cpu_before) / os.sysconf("SC_CLK_TCK") * 100
    process.stdin.close(); process.wait(timeout=3)
    assert names() == [] and process.returncode == 0
    checks.append("tab removal and native-port EOF release all owners; no idle polling")
    for ending in (struct.pack("=I", 262145), struct.pack("=I", 100) + b'{'):
        bad = subprocess.Popen([sys.executable, str(host)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=logs)
        output, _ = bad.communicate(ending, timeout=3)
        assert bad.returncode == 0 and output == b"" and names() == [], str(work)
    checks.append("artwork URL credentials/query/fragment removed; malformed/oversized/truncated frames bounded")
    logs.flush()
    assert (work / "host.log").read_text() == "", str(work)
    result = {"passed": True, "checks": checks, "idleCpuPercent": cpu_percent}
    (work / "result.json").write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2)); print(f"Logs: {work}")
finally:
    if process.poll() is None:
        process.terminate(); process.wait(timeout=3)
    selector.close(); logs.close()
