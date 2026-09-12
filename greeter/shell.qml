//@ pragma ShellId quickshell-greeter
import Quickshell
import QtQuick

ShellRoot {
    readonly property var authentication: GreeterService
    Component.onCompleted: Quickshell.watchFiles = false
    Variants {
        model: Quickshell.screens
        GreeterWindow {
            required property var modelData
            screen: modelData
        }
    }
    Connections {
        target: GreeterService
        function onSessionLaunched() { Qt.quit(); }
        function onRestartRequested() { Qt.quit(); }
    }
}
