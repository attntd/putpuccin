#!/usr/bin/python
"""Scoped, event-driven browser native messaging -> MPRIS. No files or network."""
import hashlib
import ctypes
import json
import math
import os
import signal
import struct
import sys
import time
from urllib.parse import urlsplit, urlunsplit

import dbus
import dbus.service
from dbus.mainloop.glib import DBusGMainLoop

PREFIX = "org.mpris.MediaPlayer2.quickshell_browser."
PLAYER = "org.mpris.MediaPlayer2.Player"
ROOT = "org.mpris.MediaPlayer2"
PROPERTIES = "org.freedesktop.DBus.Properties"
PATH = "/org/mpris/MediaPlayer2"
HOSTS = {"soundcloud.com", "www.soundcloud.com", "music.apple.com"}
MAX_MESSAGE = 262144
MAX_PLAYERS = 32


def text(value, limit=4096):
    if not isinstance(value, str):
        return ""
    # D-Bus strings require valid UTF-8 without NUL. JS substring boundaries
    # can split a surrogate pair even when the original page text was valid.
    return "".join("\ufffd" if char == "\x00" or 0xd800 <= ord(char) <= 0xdfff else char
        for char in value[:limit])


def number(value):
    return value if type(value) in (int, float) and math.isfinite(value) else None


def artwork(value):
    value = text(value, 16384)
    try:
        parsed = urlsplit(value)
        if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
            return ""
        if not any(parsed.hostname == domain or parsed.hostname.endswith("." + domain)
                for domain in ("mzstatic.com", "sndcdn.com")):
            return ""
        return urlunsplit((parsed.scheme, parsed.netloc, parsed.path, "", ""))
    except ValueError:
        return ""


def emit_message(value):
    encoded = json.dumps(value, ensure_ascii=True, separators=(",", ":")).encode()
    try:
        sys.stdout.buffer.write(struct.pack("=I", len(encoded)) + encoded)
        sys.stdout.buffer.flush()
    except BrokenPipeError:
        loop.quit()


class Player(dbus.service.Object):
    def __init__(self, tab_id, update):
        self.tab_id = tab_id
        # Every tab needs its own connection: MPRIS fixes the object path, and
        # a D-Bus connection cannot register different objects at the same path.
        self.bus = dbus.SessionBus(private=True)
        self.owner = None
        registered = False
        try:
            self.owner = dbus.service.BusName(PREFIX + f"p{os.getpid()}.t{tab_id}", self.bus,
                allow_replacement=False, replace_existing=False, do_not_queue=True)
            super().__init__(self.bus, PATH)
            registered = True
            self.props = {}
            self.position = None
            self.rate = 1.0
            self.updated_at = time.monotonic()
            self.track = ""
            self.apply(update)
        except Exception:
            if registered:
                self.remove_from_connection()
            self.owner = None
            self.bus.close()
            raise

    def close(self):
        self.remove_from_connection()
        self.owner = None
        self.bus.close()

    def position_now(self):
        if self.position is None:
            return None
        elapsed = time.monotonic() - self.updated_at if self.props["PlaybackStatus"] == "Playing" else 0
        position = max(0, self.position + elapsed * self.rate)
        length = self.props["Metadata"].get("mpris:length")
        return min(position, int(length) / 1e6) if length is not None else position

    def apply(self, update):
        previous_position = self.position_now() if self.props else None
        title, artist, album = (text(update.get(key)) for key in ("title", "artist", "album"))
        host = update["sourceHost"]
        # Stable for this actual media, unaffected by asynchronous artwork/title-of-page updates.
        track_hash = hashlib.sha256(json.dumps([host, title, artist, album], ensure_ascii=True).encode()).hexdigest()[:24]
        self.track = f"/quickshell/browser/t{self.tab_id}/{track_hash}"
        metadata = {"mpris:trackid": dbus.ObjectPath(self.track),
            "xesam:title": title, "xesam:artist": dbus.Array([artist] if artist else [], signature="s"),
            "xesam:album": album,
            "browser:pageTitle": text(update.get("pageTitle")), "browser:sourceHost": host,
            "browser:tabKey": str(self.tab_id)}
        art = artwork(update.get("artUrl"))
        if art:
            metadata["mpris:artUrl"] = art
        position = number(update.get("position"))
        self.position = position if position is not None and 0 <= position <= 1e9 else None
        duration = number(update.get("duration"))
        # Quickshell remembers Position support. With no current position, omit
        # the range too, so it cannot display an invented interpolated timeline.
        if duration is not None and 0 < duration <= 1e9 and self.position is not None:
            metadata["mpris:length"] = dbus.Int64(round(duration * 1e6))
        rate = number(update.get("playbackRate"))
        self.rate = rate if rate is not None and 0 < rate <= 16 else 1.0
        self.updated_at = time.monotonic()
        state = update.get("state")
        if state not in ("Playing", "Paused", "Stopped"):
            state = "Stopped"
        props = {"PlaybackStatus": state, "Metadata": dbus.Dictionary(metadata, signature="sv"),
            "Rate": float(self.rate), "MinimumRate": float(self.rate), "MaximumRate": float(self.rate),
            "CanControl": True, "CanPlay": update.get("canPlay") is True,
            "CanPause": update.get("canPause") is True, "CanGoNext": update.get("canNext") is True,
            "CanGoPrevious": update.get("canPrevious") is True,
            "CanSeek": update.get("canSeek") is True and "mpris:length" in metadata}
        changed = {key: value for key, value in props.items() if self.props.get(key) != value}
        self.props = props
        if previous_position is None and self.position is not None:
            # Announce the formerly optional property once when it becomes available.
            changed["Position"] = dbus.Int64(round(self.position * 1e6))
        if changed:
            self.PropertiesChanged(PLAYER, changed, [])
        if self.position is not None and (previous_position is None or abs(previous_position - self.position) > .5):
            self.Seeked(dbus.Int64(round(self.position * 1e6)))

    @dbus.service.method(PROPERTIES, in_signature="s", out_signature="a{sv}")
    def GetAll(self, interface):
        if interface == ROOT:
            return {"Identity": "Zen Browser", "DesktopEntry": "zen", "CanQuit": False,
                "CanRaise": False, "HasTrackList": False,
                "SupportedUriSchemes": dbus.Array([], signature="s"),
                "SupportedMimeTypes": dbus.Array([], signature="s")}
        if interface != PLAYER:
            raise dbus.exceptions.DBusException("Unknown interface", name="org.freedesktop.DBus.Error.InvalidArgs")
        props = dict(self.props)
        position = self.position_now()
        if position is not None:
            props["Position"] = dbus.Int64(round(position * 1e6))
        return props

    @dbus.service.method(PROPERTIES, in_signature="ss", out_signature="v")
    def Get(self, interface, key):
        props = self.GetAll(interface)
        if key not in props:
            raise dbus.exceptions.DBusException("Property unavailable", name="org.freedesktop.DBus.Error.InvalidArgs")
        return props[key]

    @dbus.service.method(PROPERTIES, in_signature="ssv")
    def Set(self, interface, key, value):
        raise dbus.exceptions.DBusException("Read only property", name="org.freedesktop.DBus.Error.PropertyReadOnly")

    @dbus.service.signal(PROPERTIES, signature="sa{sv}as")
    def PropertiesChanged(self, interface, changed, invalidated): pass

    @dbus.service.signal(PLAYER, signature="x")
    def Seeked(self, position): pass

    def command(self, command, capability, **extra):
        if self.props.get(capability):
            emit_message({"type": "command", "tabId": self.tab_id, "command": command, **extra})

    @dbus.service.method(PLAYER)
    def Play(self): self.command("Play", "CanPlay")
    @dbus.service.method(PLAYER)
    def Pause(self): self.command("Pause", "CanPause")
    @dbus.service.method(PLAYER)
    def PlayPause(self):
        self.command("PlayPause", "CanPause" if self.props["PlaybackStatus"] == "Playing" else "CanPlay")
    @dbus.service.method(PLAYER)
    def Next(self): self.command("Next", "CanGoNext")
    @dbus.service.method(PLAYER)
    def Previous(self): self.command("Previous", "CanGoPrevious")
    @dbus.service.method(PLAYER, in_signature="ox")
    def SetPosition(self, track, position):
        if str(track) == self.track:
            self.seek(float(position) / 1e6)
    @dbus.service.method(PLAYER, in_signature="x")
    def Seek(self, offset):
        position = self.position_now()
        if position is not None:
            self.seek(position + float(offset) / 1e6)

    def seek(self, position):
        duration = self.props["Metadata"].get("mpris:length")
        if duration is not None and math.isfinite(position):
            self.command("Seek", "CanSeek", position=max(0, min(int(duration) / 1e6, position)))


def handle(message):
    if not isinstance(message, dict):
        return
    tab = message.get("tabId")
    if type(tab) is not int or not 0 <= tab <= 2147483647:
        return
    if message.get("type") == "remove":
        player = players.pop(tab, None)
        if player:
            player.close()
    elif message.get("type") == "update" and message.get("sourceHost") in HOSTS:
        if tab in players:
            players[tab].apply(message)
        elif len(players) < MAX_PLAYERS:
            players[tab] = Player(tab, message)


def read_input(channel, condition, userdata):
    try:
        chunk = os.read(sys.stdin.fileno(), 65536)
        if not chunk:
            loop.quit()
            return False
        incoming.extend(chunk)
        while len(incoming) >= 4:
            size = struct.unpack("=I", incoming[:4])[0]
            if size == 0 or size > MAX_MESSAGE:
                loop.quit()
                return False
            if len(incoming) < size + 4:
                break
            encoded = bytes(incoming[4:size + 4])
            del incoming[:size + 4]
            try:
                handle(json.loads(encoded))
            except (ValueError, TypeError, OverflowError, RecursionError, dbus.DBusException):
                pass
    except OSError:
        loop.quit()
        return False
    return True


class MainLoop:
    """Use the already installed GLib ABI; python-dbus does not require PyGObject."""
    def __init__(self):
        self.glib = ctypes.CDLL("libglib-2.0.so.0")
        self.glib.g_main_loop_new.argtypes = [ctypes.c_void_p, ctypes.c_int]
        self.glib.g_main_loop_new.restype = ctypes.c_void_p
        self.pointer = self.glib.g_main_loop_new(None, False)
        self.glib.g_main_loop_run.argtypes = [ctypes.c_void_p]
        self.glib.g_main_loop_quit.argtypes = [ctypes.c_void_p]
        self.glib.g_io_channel_unix_new.argtypes = [ctypes.c_int]
        self.glib.g_io_channel_unix_new.restype = ctypes.c_void_p
        io_callback_type = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p)
        self.io_callback = io_callback_type(read_input)
        self.glib.g_io_add_watch.argtypes = [ctypes.c_void_p, ctypes.c_int, io_callback_type, ctypes.c_void_p]
        self.channel = self.glib.g_io_channel_unix_new(sys.stdin.fileno())
        self.glib.g_io_add_watch(self.channel, 1 | 16 | 8, self.io_callback, None)
        signal_callback_type = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p)
        self.signal_callback = signal_callback_type(lambda data: self.quit() or False)
        self.glib.g_unix_signal_add.argtypes = [ctypes.c_int, signal_callback_type, ctypes.c_void_p]
        self.glib.g_unix_signal_add(signal.SIGTERM, self.signal_callback, None)
        self.glib.g_unix_signal_add(signal.SIGINT, self.signal_callback, None)

    def run(self): self.glib.g_main_loop_run(self.pointer)
    def quit(self): self.glib.g_main_loop_quit(self.pointer)


if __name__ == "__main__":
    DBusGMainLoop(set_as_default=True)
    players = {}
    incoming = bytearray()
    loop = MainLoop()
    try:
        loop.run()
    finally:
        for player in players.values():
            player.close()
