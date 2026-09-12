#!/usr/bin/env python3
"""Private-bus login1 double; passes real inhibitor FDs, never sleeps the host."""
import ctypes
import json
import os
from pathlib import Path
import sys
import time

import dbus
import dbus.service
from dbus.mainloop.glib import DBusGMainLoop

# dbus-python and GLib are installed on the desktop; PyGObject is optional.
# Keep the same small GLib binding approach as the network/media test doubles.
glib = ctypes.CDLL('libglib-2.0.so.0')
FdCallback = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_void_p)
glib.g_main_loop_new.argtypes = [ctypes.c_void_p, ctypes.c_int]
glib.g_main_loop_new.restype = ctypes.c_void_p
glib.g_main_loop_run.argtypes = [ctypes.c_void_p]
glib.g_unix_fd_add.argtypes = [ctypes.c_int, ctypes.c_int, FdCallback, ctypes.c_void_p]
callbacks = []

MANAGER = 'org.freedesktop.login1.Manager'
SESSION = 'org.freedesktop.login1.Session'
CONTROL = 'org.quickshell.test.Sleep'
SESSION_PATH = '/org/freedesktop/login1/session/test'
WORK = Path(sys.argv[1])


# loginctl uses /session/auto directly; hypridle resolves GetSession("auto").
class Session(dbus.service.FallbackObject):
    @dbus.service.method(SESSION, in_signature='', out_signature='')
    def Lock(self):
        manager.record('lock-request')
        bus.send_message(dbus.lowlevel.SignalMessage(SESSION_PATH, SESSION, 'Lock'))


class Logind(dbus.service.Object):
    def __init__(self, bus, session):
        super().__init__(bus, '/org/freedesktop/login1')
        self.session = session
        self.active = []
        self.events = []
        self.issued = 0
        self.record('ready')

    def record(self, name, **values):
        self.events.append(dict(event=name, ns=time.monotonic_ns(), **values))
        target = WORK / 'leases.json'
        temp = target.with_suffix('.tmp')
        temp.write_text(json.dumps(dict(active=self.active, events=self.events)))
        temp.replace(target)

    @dbus.service.method(MANAGER, in_signature='s', out_signature='o')
    def GetSession(self, session):
        return dbus.ObjectPath(SESSION_PATH)

    @dbus.service.method(MANAGER, in_signature='s', out_signature='')
    def LockSession(self, session):
        self.session.Lock()

    @dbus.service.method('org.freedesktop.DBus.Properties', in_signature='ss', out_signature='v')
    def Get(self, interface, name):
        if interface == MANAGER and name == 'BlockInhibited':
            return dbus.String('')
        raise dbus.exceptions.DBusException('Unknown property',
                                           name='org.freedesktop.DBus.Error.UnknownProperty')

    @dbus.service.method(MANAGER, in_signature='ssss', out_signature='h')
    def Inhibit(self, what, who, why, mode):
        if (WORK / 'deny-inhibit').exists():
            self.record('inhibit-denied')
            raise dbus.exceptions.DBusException('Synthetic permission denial',
                                               name='org.freedesktop.DBus.Error.AccessDenied')
        reader, writer = os.pipe2(os.O_CLOEXEC | os.O_NONBLOCK)
        self.issued += 1
        identity = self.issued
        self.active.append(identity)
        self.record('acquire', id=identity, what=str(what), who=str(who), mode=str(mode))

        def released(fd, condition):
            if os.read(fd, 1) == b'':
                os.close(fd)
                self.active.remove(identity)
                self.record('release', id=identity)
                return 0
            return 1

        callback = FdCallback(lambda fd, condition, data: released(fd, condition))
        callbacks.append(callback)
        glib.g_unix_fd_add(reader, 1 | 16, callback, None)  # G_IO_IN | G_IO_HUP
        descriptor = dbus.types.UnixFd(writer)
        os.close(writer)  # UnixFd owns its duplicate until D-Bus sends it.
        return descriptor

    @dbus.service.signal(MANAGER, signature='b')
    def PrepareForSleep(self, sleeping):
        pass

    @dbus.service.method(CONTROL, in_signature='b', out_signature='')
    def Prepare(self, sleeping):
        self.record('prepare', sleeping=bool(sleeping))
        self.PrepareForSleep(sleeping)


DBusGMainLoop(set_as_default=True)
bus = dbus.bus.BusConnection(os.environ['DBUS_SESSION_BUS_ADDRESS'])
name = dbus.service.BusName('org.freedesktop.login1', bus=bus)
session = Session(bus, '/org/freedesktop/login1/session')
manager = Logind(bus, session)
glib.g_main_loop_run(glib.g_main_loop_new(None, False))
