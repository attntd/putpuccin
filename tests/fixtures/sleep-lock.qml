import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// This fixture runs only on the disposable compositor. Test-only unlock IPC
// must never be included in the installed shell.
ShellRoot {
    id: root
    property bool requested: false
    WlSessionLock {
        id: sessionLock
        locked: root.requested
        onSecureChanged: console.log("NATIVE_SECURE " + secure)
        WlSessionLockSurface { color: "black" }
    }
    IpcHandler {
        target: "sleepLockTest"
        function setLocked(value: bool): void { root.requested = value; }
        function status(): string {
            return JSON.stringify({ locked: root.requested, secure: sessionLock.secure });
        }
    }
    IpcHandler {
        target: "lockscreen"
        function lock(): void { root.requested = true; }
    }
}
