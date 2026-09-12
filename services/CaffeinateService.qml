pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.core
import SessionNative 1.0

Singleton {
    id: root
    readonly property string mode: controller.mode
    readonly property bool active: mode !== "off"
    readonly property bool busy: controller.busy
    readonly property string errorMessage: controller.failed ? Strings.caffeinateFailed : ""
    readonly property bool preventDisplaySleep: mode === "presentation"
    readonly property bool preventLock: mode === "background" || mode === "presentation"
    readonly property var modes: [
        {id: "background", label: Strings.caffeinateBackground,
            tileLabel: Strings.caffeinateBackground, description: Strings.caffeinateBackgroundHint},
        {id: "presentation", label: Strings.caffeinatePresentation,
            tileLabel: Strings.caffeinatePresentation, description: Strings.caffeinatePresentationHint},
        {id: "secure-background", label: Strings.caffeinateSecureBackground,
            tileLabel: Strings.caffeinateSecureBackgroundShort, description: Strings.caffeinateSecureBackgroundHint}
    ]
    readonly property string label: modes.find(entry => entry.id === mode)?.tileLabel || Strings.caffeinate

    CaffeinateController { id: controller }

    function setEnabled(value) {
        setMode(value ? (root.active ? root.mode : "presentation") : "off");
    }

    function setMode(value) {
        controller.setMode(value, Strings.caffeinateReason);
    }

    IpcHandler {
        target: "caffeinate"
        function status(): string {
            return JSON.stringify({active: root.active, mode: root.mode, busy: root.busy,
                preventDisplaySleep: root.preventDisplaySleep, preventLock: root.preventLock,
                preventSleep: root.active, error: root.errorMessage});
        }
        function setEnabled(enabled: bool): void { root.setEnabled(enabled); }
        function setMode(mode: string): void { root.setMode(mode); }
    }
}
