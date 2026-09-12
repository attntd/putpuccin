pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.components
import qs.core
import qs.services

ListView {
    id: root
    required property var devices
    required property string screenName
    property bool pairingList: false
    property int maximumRows: 5
    property real maximumHeight: maximumRows * Metrics.popupRowHeight + Math.max(0, maximumRows - 1) * spacing
    model: devices
    spacing: Metrics.space6
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    activeFocusOnTab: count > 0 || activeFocus
    keyNavigationEnabled: true
    implicitHeight: count === 0 ? emptyState.implicitHeight + Metrics.space8
        : Math.min(maximumHeight, count * Metrics.popupRowHeight + Math.max(0, count - 1) * spacing)
    ScrollBar.vertical: ScrollBar {
        id: scrollBar
        objectName: "bluetoothDeviceScrollBar"
        policy: root.contentHeight > root.height ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
        minimumSize: 0.08
        contentItem: Rectangle {
            implicitWidth: Metrics.space6
            radius: width / 2
            color: scrollBar.pressed ? Theme.accent : Theme.overlay1
        }
    }

    function activateCurrent() { if (currentItem) currentItem.activate(); }
    onActiveFocusChanged: { if (activeFocus && currentIndex < 0 && count > 0) currentIndex = 0; }
    Keys.onReturnPressed: activateCurrent()
    Keys.onEnterPressed: activateCurrent()
    Keys.onSpacePressed: activateCurrent()
    Keys.onRightPressed: { if (!pairingList && currentItem) currentItem.manage(); }
    Keys.onPressed: event => {
        if (event.key === Qt.Key_Home) {
            currentIndex = 0; positionViewAtBeginning(); event.accepted = true;
        } else if (event.key === Qt.Key_End) {
            currentIndex = count - 1; positionViewAtEnd(); event.accepted = true;
        }
        if (event.key === Qt.Key_F2 && !pairingList && currentItem) {
            currentItem.manage(); event.accepted = true;
        }
    }

    delegate: Item {
        id: row
        required property var modelData
        required property int index
        readonly property bool busy: BluetoothService.deviceBusy(modelData)
        readonly property string label: BluetoothService.deviceName(modelData)
        readonly property string status: busy
            ? (modelData.dbusPath === BluetoothService.pairingPath ? Strings.bluetoothPairing
                : BluetoothService.action === "disconnect" ? Strings.bluetoothDisconnecting
                : BluetoothService.action === "forget" ? Strings.bluetoothForgetting
                : BluetoothService.action === "rename" ? Strings.bluetoothWorking : Strings.connecting)
            : modelData.connected ? Strings.connected : root.pairingList ? Strings.bluetoothPair : Strings.disconnected
        width: ListView.view.width - (root.contentHeight > root.height ? Metrics.space12 : 0)
        height: Metrics.popupRowHeight

        function activate() {
            if (!connection.enabled) return;
            if (root.pairingList) BluetoothService.pairDevice(modelData, root.screenName);
            else BluetoothService.toggleDevice(modelData);
        }
        function manage() {
            if (!settings.enabled || root.pairingList) return;
            root.currentIndex = index;
            BluetoothService.openManagement(modelData, root.screenName);
        }
        ItemDelegate {
            id: connection
            anchors.fill: parent
            enabled: !!row.modelData.adapter && row.modelData.adapter.enabled && !row.busy
                && !BluetoothService.pairingBusy && !BluetoothService.actionBusy
            activeFocusOnTab: false
            Accessible.name: row.label + ", " + row.status
            onClicked: { root.currentIndex = row.index; row.activate(); }
            background: Rectangle {
                radius: 10
                color: Theme.controlBackground(row.modelData.connected ? Theme.accent : Theme.text,
                    connection.hovered || settings.hovered, connection.down,
                    row.modelData.connected || (root.activeFocus && row.ListView.isCurrentItem))
            }
            contentItem: Item {}
        }
        // Keep settings outside the disabled connection control while sharing
        // its tile: saved-device details also work with Bluetooth powered off.
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: connection.leftPadding
            anchors.rightMargin: connection.rightPadding
            spacing: Metrics.space8
            Text {
                text: Icons.device
                color: row.modelData.connected ? Theme.accent : Theme.subtext0
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.iconMedium
            }
            Text {
                objectName: "bluetoothDeviceName_" + row.index
                text: row.label
                textFormat: Text.PlainText
                color: Theme.text
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.fontSmall
                elide: Text.ElideRight
                Layout.fillWidth: true
                Layout.minimumWidth: 0
            }
            ActionButton {
                id: settings
                objectName: "bluetoothDeviceSettings_" + row.index
                visible: !root.pairingList
                Layout.minimumWidth: Metrics.minHitSize
                Layout.preferredWidth: Metrics.minHitSize
                Layout.preferredHeight: Metrics.popupRowHeight
                enabled: !BluetoothService.pairingBusy && !BluetoothService.actionBusy && !row.busy
                glyph: Icons.more
                borderless: true
                Accessible.name: Strings.bluetoothDeviceSettings.arg(row.label)
                onClicked: row.manage()
            }
            Text {
                visible: row.modelData.batteryAvailable
                text: Math.round(row.modelData.battery * 100) + "%"
                color: Theme.subtext0
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.fontSmall
            }
            Text {
                visible: !root.pairingList || row.busy
                text: row.status
                color: row.modelData.connected ? Theme.accent : Theme.subtext0
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.fontSmall
            }
        }
    }

    EmptyState {
        id: emptyState
        anchors.centerIn: parent
        width: parent.width - Metrics.space16
        visible: root.count === 0
        icon: BluetoothService.enabled ? Icons.bluetooth : Icons.bluetoothOff
        title: !BluetoothService.available ? Strings.unavailable
            : !BluetoothService.enabled ? Strings.bluetoothUnavailable
            : root.pairingList ? Strings.bluetoothNoNearby : Strings.noSavedDevices
        detail: root.pairingList && BluetoothService.enabled ? Strings.bluetoothDiscoveryHint : ""
    }
}
