pragma ComponentBehavior: Bound

import QtQuick
import qs.components
import qs.core
import qs.popups
import qs.services

Item {
    id: root
    property var barWindow
    property var shellScreen
    readonly property string screenName: HyprlandService.screenName(shellScreen)
    readonly property string expansionSurface: "bluetooth"
    readonly property int expansionWidth: Math.min(Metrics.popupWidth,
        shellScreen && shellScreen.width > 0 ? shellScreen.width - 2 * Metrics.space12 : Metrics.popupWidth)
    readonly property Component expansionComponent: bluetoothExpansion
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    BarButton {
        id: button
        anchors.fill: parent
        icon: !BluetoothService.enabled ? Icons.bluetoothOff
            : BluetoothService.connectedCount > 0 ? Icons.bluetoothConnected : Icons.bluetooth
        iconForeground: BluetoothService.enabled ? Theme.accent : Theme.text
        text: Settings.option("bluetooth", "presentation", "adaptive") === "label" ? Strings.bluetooth : ""
        compact: Settings.option("bluetooth", "presentation", "adaptive") !== "label"
        warning: !BluetoothService.available
        active: SurfaceManager.isOpen("bluetooth", root.screenName)
        tooltip: BluetoothService.available ? (BluetoothService.enabled ? Strings.bluetoothEnabled : Strings.bluetoothDisabled) : Strings.unavailable
        onClicked: ModuleActions.run("bluetooth", "primary", root.screenName)
        onRightClicked: ModuleActions.run("bluetooth", "secondary", root.screenName)
    }

    Component {
        id: bluetoothExpansion
        BluetoothPopup {
            screenName: root.screenName
            embedded: true
            maximumHeight: root.shellScreen && root.shellScreen.height > 0
                ? root.shellScreen.height - Settings.topMargin - Settings.barHeight - 2 * Metrics.space12 : 700
        }
    }
}
