pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.components
import qs.core
import qs.services
import qs.modules.bluetooth

PopupFrame {
    id: root
    required property string screenName
    keyboardNavigationEnabled: true
    property real maximumHeight: 700
    property bool showAvailable: false
    readonly property bool ownsSurface: !embedded || SurfaceManager.isOpen("bluetooth", screenName)
    readonly property bool pairingHere: BluetoothService.pairingBusy && BluetoothService.pairingScreenName === screenName
    readonly property bool managingHere: !!BluetoothService.managementPath && BluetoothService.managementScreenName === screenName
    readonly property bool keepOpen: ownsSurface && (showAvailable || pairingHere || managingHere)
    readonly property bool wantsDiscovery: ownsSurface && showAvailable && !managingHere && BluetoothService.enabled
    readonly property var savedDevices: sortedDevices(true)
    readonly property var availableDevices: sortedDevices(false)

    function sortedDevices(saved) {
        const values = BluetoothService.devices.filter(device => device.adapter === BluetoothService.adapter
            && (saved ? device.paired || device.bonded || device.connected
                : !device.paired && !device.bonded && !device.connected));
        values.sort((a, b) => {
            if (a.connected !== b.connected) return a.connected ? -1 : 1;
            const first = BluetoothService.deviceName(a), second = BluetoothService.deviceName(b);
            if ((first === Strings.bluetoothUnnamed) !== (second === Strings.bluetoothUnnamed))
                return first === Strings.bluetoothUnnamed ? 1 : -1;
            return first.localeCompare(second) || a.address.localeCompare(b.address);
        });
        return values;
    }

    onWantsDiscoveryChanged: BluetoothService.setDiscovery(screenName, wantsDiscovery)
    onOwnsSurfaceChanged: {
        if (!ownsSurface && pairingHere) BluetoothService.cancelPairing();
        if (!ownsSurface && managingHere) BluetoothService.closeManagement(screenName);
    }
    onManagingHereChanged: { if (!managingHere) Qt.callLater(() => savedList.forceActiveFocus()); }
    onShowAvailableChanged: { if (!showAvailable) Qt.callLater(() => pairButton.forceActiveFocus()); }
    Component.onCompleted: BluetoothService.acquirePopup(screenName)
    Component.onDestruction: BluetoothService.releasePopup(screenName)

    ColumnLayout {
        width: parent.width
        spacing: Metrics.space8

        ToggleRow {
            id: radioToggle
            title: Strings.bluetooth
            checked: BluetoothService.enabled
            enabled: BluetoothService.available && BluetoothService.state !== "loading" && !BluetoothService.actionBusy
            Layout.fillWidth: true
            onToggled: checked => BluetoothService.setEnabled(checked)
        }

        Loader {
            id: adapterPicker
            active: BluetoothService.adapters.length > 1 && !root.managingHere
            visible: active
            Layout.fillWidth: true
            sourceComponent: ColumnLayout {
                spacing: Metrics.space4
                SectionTitle { text: Strings.bluetoothAdapter }
                Repeater {
                    model: BluetoothService.adapters
                    ActionButton {
                        required property var modelData
                        objectName: "bluetoothAdapter_" + modelData.adapterId
                        text: modelData.name + " (" + modelData.adapterId + ")"
                        accent: modelData === BluetoothService.adapter
                        enabled: !BluetoothService.pairingBusy && !BluetoothService.actionBusy
                        borderless: true
                        Layout.fillWidth: true
                        onClicked: BluetoothService.selectAdapter(modelData.dbusPath)
                    }
                }
            }
        }
        Loader {
            active: root.managingHere
            visible: active
            Layout.fillWidth: true
            sourceComponent: DeviceDetails { screenName: root.screenName }
        }
        SectionTitle { text: Strings.savedDevices; visible: !root.managingHere && !root.showAvailable }
        BluetoothDeviceList {
            id: savedList
            objectName: "savedBluetoothDevices"
            visible: !root.managingHere && !root.showAvailable
            devices: root.savedDevices
            screenName: root.screenName
            maximumRows: 5
            Layout.fillWidth: true
        }

        ActionButton {
            id: pairButton
            objectName: "pairNewDevice"
            visible: !root.pairingHere && !root.managingHere && !root.showAvailable
            text: Strings.pairNewDevice
            borderless: true
            glyph: Icons.bluetooth
            enabled: BluetoothService.enabled && !BluetoothService.pairingBusy && !BluetoothService.actionBusy
            implicitHeight: Metrics.popupRowHeight
            Layout.fillWidth: true
            onClicked: root.showAvailable = true
        }

        Loader {
            active: root.showAvailable && !root.pairingHere && !root.managingHere
            visible: active
            Layout.fillWidth: true
            sourceComponent: DevicePicker {
                devices: root.availableDevices
                screenName: root.screenName
                maximumHeight: root.maximumHeight - 2 * root.padding - radioToggle.implicitHeight - Metrics.space16
                    - (adapterPicker.active ? adapterPicker.implicitHeight + Metrics.space8 : 0)
                    - (feedback.visible ? feedback.implicitHeight + Metrics.space8 : 0)
                onBack: root.showAvailable = false
            }
        }

        Loader {
            active: root.pairingHere
            visible: active
            Layout.fillWidth: true
            sourceComponent: PairingPrompt { service: BluetoothService }
        }

        Text {
            visible: BluetoothService.pairingBusy && !root.pairingHere
            text: Strings.bluetoothPairElsewhere
            color: Theme.subtext0
            font.family: Metrics.fontFamily
            font.pixelSize: Metrics.fontSmall
            wrapMode: Text.Wrap
            Layout.fillWidth: true
        }

        Text {
            id: feedback
            objectName: "bluetoothFeedback"
            visible: text.length > 0
            text: BluetoothService.errorMessage || BluetoothService.statusMessage
            color: BluetoothService.errorMessage ? Theme.red : Theme.green
            font.family: Metrics.fontFamily
            font.pixelSize: Metrics.fontSmall
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            Layout.fillWidth: true
        }
    }
}
