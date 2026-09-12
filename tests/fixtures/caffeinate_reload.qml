//@ pragma ShellId caffeinate-reload-test
import QtQuick
import Quickshell
import Quickshell.Io
import qs.services

ShellRoot {
    id: root
    readonly property var caffeinate: CaffeinateService
    readonly property string generation: Date.now() + "-" + Math.random()
    property string initialMode: "unset"
    property int failures: 0
    Component.onCompleted: {
        Quickshell.watchFiles = false;
        initialMode = CaffeinateService.mode;
    }
    Connections {
        target: Quickshell
        function onReloadCompleted() { Quickshell.inhibitReloadPopup(); }
        function onReloadFailed(errorString) {
            Quickshell.inhibitReloadPopup();
            root.failures++;
        }
    }
    IpcHandler {
        target: "reloadtest"
        function status(): string {
            return JSON.stringify({generation: root.generation, initialMode: root.initialMode,
                failures: root.failures});
        }
        function reload(hard: bool): void { Qt.callLater(() => Quickshell.reload(hard)); }
    }
}
