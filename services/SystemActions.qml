pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io

Singleton {
    id: root

    property var capabilities: ({
        "lock": true,
        "suspend": true,
        "hibernate": false,
        "logout": true,
        "reboot": true,
        "poweroff": true
    })
    property bool busy: false
    property string pendingAction: ""
    property string errorMessage: ""

    signal succeeded(string actionId)
    signal failed(string actionId, string message)

    function available(actionId) {
        return root.capabilities[actionId] === true;
    }

    function execute(actionId) {
        if (root.busy || !root.available(actionId))
            return;
        root.errorMessage = "";
        root.pendingAction = actionId;

        if (actionId === "logout") {
            Hyprland.dispatch(Hyprland.usingLua ? "hl.dsp.exit()" : "exit");
            root.succeeded(actionId);
            root.pendingAction = "";
            return;
        }
        const unitAction = actionId === "poweroff" ? "poweroff" : actionId;
        // QProcess is already starting before its asynchronous started signal.
        root.busy = true;
        // lock-screen waits for the compositor and can launch the independent
        // fallback. Its IPC calls LockService directly, without re-entering here.
        if (actionId === "lock")
            actionProcess.exec([Quickshell.shellPath("scripts/lock-screen")]);
        else
            actionProcess.exec(["systemctl", unitAction]);
    }

    function finishAction(exitCode) {
        const completedAction = root.pendingAction;
        if (!completedAction)
            return;
        root.busy = false;
        root.pendingAction = "";
        if (exitCode === 0) {
            root.succeeded(completedAction);
        } else {
            root.errorMessage = actionError.text.trim() || "Operacja została odrzucona.";
            root.failed(completedAction, root.errorMessage);
        }
    }

    Process {
        id: capabilityProcess
        command: [Quickshell.shellPath("scripts/power-capabilities")]
        running: true
        stdout: StdioCollector {
            id: capabilityOutput
        }
        onExited: exitCode => {
            if (exitCode !== 0)
                return;
            const next = Object.assign({}, root.capabilities);
            for (const line of capabilityOutput.text.trim().split("\n")) {
                const parts = line.split("=");
                if (parts.length === 2 && next[parts[0]] !== undefined)
                    next[parts[0]] = parts[1] === "yes" || parts[1] === "challenge";
            }
            root.capabilities = next;
        }
    }

    Process {
        id: actionProcess
        stderr: StdioCollector {
            id: actionError
        }
        onExited: exitCode => root.finishAction(exitCode)
        // FailedToStart emits runningChanged, but not exited in Quickshell 0.3.1.
        onRunningChanged: if (!running) Qt.callLater(() => {
            if (!actionProcess.running && root.busy)
                root.finishAction(-1);
        })
    }
}
