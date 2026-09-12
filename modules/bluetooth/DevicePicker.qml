pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.components
import qs.core
import qs.services

ColumnLayout {
    id: root
    required property string screenName
    required property var devices
    property real maximumHeight: 600
    signal back()
    spacing: Metrics.space8

    ActionButton {
        id: backButton
        objectName: "bluetoothPickerBack"
        text: Strings.bluetoothBack
        borderless: true
        Layout.fillWidth: true
        onClicked: root.back()
    }
    SectionTitle { id: title; text: Strings.bluetoothNearbyCount.arg(root.devices.length) }
    Text {
        id: subtitle
        text: BluetoothService.discovering ? Strings.bluetoothSearching : Strings.bluetoothPickerHint
        color: Theme.subtext0
        font.family: Metrics.fontFamily
        font.pixelSize: Metrics.fontSmall
        wrapMode: Text.Wrap
        Layout.fillWidth: true
    }
    BluetoothDeviceList {
        id: list
        objectName: "availableBluetoothDevices"
        devices: root.devices
        screenName: root.screenName
        pairingList: true
        maximumHeight: Math.min(Metrics.bluetoothPickerListHeight, Math.max(Metrics.popupRowHeight,
            root.maximumHeight - backButton.implicitHeight - title.implicitHeight - subtitle.implicitHeight - 3 * root.spacing))
        Layout.fillWidth: true
    }
    Component.onCompleted: Qt.callLater(() => list.forceActiveFocus())
}
