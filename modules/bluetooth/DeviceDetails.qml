pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.components
import qs.core
import qs.services

ColumnLayout {
    id: root
    required property string screenName
    readonly property var device: BluetoothService.managementDevice
    property bool confirmingForget: false
    property bool editingName: false
    readonly property bool busy: BluetoothService.actionBusy
    spacing: Metrics.space8

    function saveName(value) { BluetoothService.manageDevice("rename", screenName, value); }
    function focusCurrentControl() {
        Qt.callLater(() => {
            if (root.confirmingForget) cancelForget.forceActiveFocus();
            else if (root.editingName) nameInput.forceActiveFocus();
            else renameButton.forceActiveFocus();
        });
    }
    onConfirmingForgetChanged: focusCurrentControl()
    onEditingNameChanged: focusCurrentControl()
    Component.onCompleted: focusCurrentControl()

    Connections {
        target: BluetoothService
        function onDeviceRenamed(path) {
            if (root.device && root.device.dbusPath === path) root.editingName = false;
        }
    }

    ActionButton {
        objectName: "bluetoothBack"
        text: Strings.bluetoothBack
        borderless: true
        Layout.fillWidth: true
        onClicked: BluetoothService.closeManagement(root.screenName)
    }
    RowLayout {
        Layout.fillWidth: true
        spacing: Metrics.space8
        Text {
            objectName: "bluetoothDetailsName"
            text: BluetoothService.deviceName(root.device)
            textFormat: Text.PlainText
            color: Theme.text
            font.family: Metrics.fontFamily
            font.pixelSize: Metrics.fontBody
            font.weight: Font.DemiBold
            elide: Text.ElideRight
            Layout.fillWidth: true
            Layout.minimumWidth: 0
            Layout.alignment: Qt.AlignBaseline
        }
        Text {
            objectName: "bluetoothDetailsAddress"
            text: root.device ? root.device.address : ""
            textFormat: Text.PlainText
            color: Theme.subtext0
            font.family: Metrics.fontFamily
            font.pixelSize: Metrics.fontSmall
            Layout.alignment: Qt.AlignBaseline
        }
    }
    ColumnLayout {
        visible: !root.confirmingForget
        Layout.fillWidth: true
        spacing: Metrics.space8
        ActionButton {
            id: renameButton
            objectName: "bluetoothRename"
            visible: !root.editingName
            text: Strings.bluetoothRename
            enabled: !root.busy && !!root.device
            borderless: true
            Layout.fillWidth: true
            onClicked: {
                nameInput.text = BluetoothService.deviceName(root.device);
                root.editingName = true;
            }
        }
        ColumnLayout {
            visible: root.editingName
            Layout.fillWidth: true
            spacing: Metrics.space8
            SectionTitle { text: Strings.bluetoothDeviceName }
            TextField {
                id: nameInput
                objectName: "bluetoothNameInput"
                text: root.device ? BluetoothService.deviceName(root.device) : ""
                enabled: !root.busy
                Layout.fillWidth: true
                implicitHeight: Metrics.popupRowHeight
                maximumLength: 248
                Accessible.name: Strings.bluetoothDeviceName
                color: Theme.text
                selectionColor: Theme.accent
                selectedTextColor: Theme.crust
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.fontBody
                selectByMouse: true
                background: Rectangle {
                    radius: 10
                    color: Theme.controlBackground(Theme.surface0)
                    border.width: nameInput.activeFocus ? Metrics.borderWidth : 0
                    border.color: Theme.accent
                }
                onAccepted: { if (save.enabled) root.saveName(text); }
            }
            ActionButton {
                id: save
                objectName: "bluetoothSaveName"
                text: Strings.bluetoothSaveName
                enabled: !root.busy && !!root.device && nameInput.text.trim().length > 0
                    && BluetoothService.validName(nameInput.text.trim())
                    && nameInput.text.trim() !== BluetoothService.deviceName(root.device)
                accent: true
                borderless: true
                Layout.fillWidth: true
                onClicked: root.saveName(nameInput.text)
            }
            ActionButton {
                objectName: "bluetoothResetName"
                text: Strings.bluetoothDefaultName
                enabled: !root.busy && !!root.device && root.device.name !== root.device.deviceName
                borderless: true
                Layout.fillWidth: true
                onClicked: root.saveName("")
            }
            ActionButton {
                objectName: "bluetoothCancelRename"
                text: Strings.cancel
                enabled: !root.busy
                borderless: true
                Layout.fillWidth: true
                onClicked: root.editingName = false
            }
        }
        ActionButton {
            objectName: "bluetoothForget"
            text: Strings.bluetoothForget
            glyph: Icons.trash
            destructive: true
            borderless: true
            enabled: !root.busy && !!root.device
            Layout.fillWidth: true
            onClicked: root.confirmingForget = true
        }
    }
    ColumnLayout {
        visible: root.confirmingForget
        Layout.fillWidth: true
        spacing: Metrics.space8
        Text {
            text: Strings.bluetoothForgetHint.arg(BluetoothService.deviceName(root.device))
            textFormat: Text.PlainText
            color: Theme.text
            font.family: Metrics.fontFamily
            font.pixelSize: Metrics.fontBody
            wrapMode: Text.Wrap
            Layout.fillWidth: true
        }
        ActionButton {
            id: cancelForget
            objectName: "bluetoothCancelForget"
            text: Strings.cancel
            enabled: !root.busy
            borderless: true
            Layout.fillWidth: true
            onClicked: root.confirmingForget = false
        }
        ActionButton {
            objectName: "bluetoothConfirmForget"
            text: Strings.bluetoothForget
            enabled: !root.busy && !!root.device
            destructive: true
            borderless: true
            Layout.fillWidth: true
            onClicked: BluetoothService.manageDevice("forget", root.screenName, "")
        }
    }
    Text {
        visible: root.busy
        text: BluetoothService.action === "forget" ? Strings.bluetoothForgetting : Strings.bluetoothWorking
        color: Theme.subtext0
        font.family: Metrics.fontFamily
        font.pixelSize: Metrics.fontSmall
        Layout.fillWidth: true
    }
}
