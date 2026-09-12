pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.components
import qs.core
import qs.services

PopupFrame {
    id: root
    required property string screenName

    function outputDeviceIcon(device) {
        if (!device)
            return Icons.device;

        const properties = device.properties || {};
        const metadata = [
            properties["device.form-factor"] || "",
            properties["device.bus"] || "",
            properties["device.icon-name"] || "",
            device.name || "",
            device.description || "",
            device.nickname || ""
        ].join(" ").toLowerCase();

        if (metadata.indexOf("headphone") >= 0 || metadata.indexOf("headset") >= 0)
            return Icons.headphones;
        if (metadata.indexOf("bluetooth") >= 0 || metadata.indexOf("bluez") >= 0)
            return Icons.bluetooth;
        if (metadata.indexOf("hdmi") >= 0 || metadata.indexOf("displayport") >= 0
                || metadata.indexOf("display-port") >= 0 || metadata.indexOf("tv") >= 0)
            return Icons.monitor;
        if (metadata.indexOf("speaker") >= 0 || metadata.indexOf("internal") >= 0
                || metadata.indexOf("wbudowany") >= 0)
            return Icons.volumeHigh;
        return Icons.device;
    }

    component DeviceList: ListView {
        id: deviceList

        required property var selectedDevice
        property string glyph: Icons.device
        property bool classifyOutput: false
        property string emptyDetail: ""

        signal deviceSelected(var device)

        clip: true
        spacing: Metrics.space6
        activeFocusOnTab: count > 0
        keyNavigationEnabled: true
        Layout.fillWidth: true
        Layout.preferredHeight: count === 0 ? 72
            : Math.min(count, 4) * 48 + Math.max(0, Math.min(count, 4) - 1) * spacing

        onActiveFocusChanged: {
            if (activeFocus && currentIndex < 0 && count > 0)
                currentIndex = 0;
        }

        Keys.onReturnPressed: {
            if (currentItem)
                currentItem.activate();
        }
        Keys.onEnterPressed: {
            if (currentItem)
                currentItem.activate();
        }
        Keys.onSpacePressed: {
            if (currentItem)
                currentItem.activate();
        }

        delegate: Rectangle {
            id: deviceDelegate

            required property var modelData
            required property int index
            readonly property bool selected: modelData === deviceList.selectedDevice

            width: ListView.view.width
            height: 48
            radius: 10
            color: selected ? Theme.controlBackground(Theme.accent, false, false, true)
                : Theme.controlBackground(Theme.surface0)
            border.width: selected || (deviceList.activeFocus && ListView.isCurrentItem) ? 1 : 0
            border.color: Theme.accent

            function activate() {
                deviceList.deviceSelected(deviceDelegate.modelData);
            }

            RowLayout {
                anchors.fill: parent
                anchors.margins: Metrics.space8

                Text {
                    text: deviceList.classifyOutput
                        ? root.outputDeviceIcon(deviceDelegate.modelData) : deviceList.glyph
                    color: deviceDelegate.selected ? Theme.accent : Theme.subtext0
                    font.family: Metrics.fontFamily
                    font.pixelSize: Metrics.iconMedium
                }

                Text {
                    text: deviceDelegate.modelData.description
                        || deviceDelegate.modelData.nickname || deviceDelegate.modelData.name
                    color: Theme.text
                    font.family: Metrics.fontFamily
                    font.pixelSize: Metrics.fontSmall
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }

                Text {
                    visible: deviceDelegate.selected
                    text: Icons.check
                    color: Theme.accent
                    font.family: Metrics.fontFamily
                    font.pixelSize: Metrics.iconSmall
                }
            }

            MouseArea {
                anchors.fill: parent
                onClicked: {
                    deviceList.currentIndex = deviceDelegate.index;
                    deviceDelegate.activate();
                }
            }
        }

        EmptyState {
            anchors.centerIn: parent
            width: parent.width
            visible: deviceList.count === 0
            title: Strings.unavailable
            detail: deviceList.emptyDetail
        }
    }

    ColumnLayout {
        width: parent.width
        spacing: Metrics.space12

        SectionTitle { text: Strings.output }

        RowLayout {
            Layout.fillWidth: true
            ActionButton {
                text: ""
                glyph: AudioService.muted ? Icons.volumeMuted
                    : AudioService.volume > 0.5 ? Icons.volumeHigh
                    : AudioService.volume > 0 ? Icons.volumeLow : Icons.volumeOff
                glyphScale: AudioService.muted ? 1.22 : 1
                implicitWidth: 42
                Layout.minimumWidth: 42
                Layout.preferredWidth: 42
                Layout.maximumWidth: 42
                onClicked: AudioService.toggleMute()
            }
            StatusSlider {
                from: 0
                to: 1
                value: AudioService.volume
                enabled: AudioService.available
                Layout.fillWidth: true
                onMoved: AudioService.setVolume(value)
            }
            Text {
                text: Math.round(AudioService.volume * 100) + "%"
                color: Theme.text
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.fontSmall
                Layout.preferredWidth: 42
                horizontalAlignment: Text.AlignRight
            }
        }

        DeviceList {
            model: AudioService.sinks
            selectedDevice: AudioService.sink
            classifyOutput: true
            emptyDetail: AudioService.errorMessage
            onDeviceSelected: device => AudioService.selectSink(device)
        }

        SectionTitle { text: Strings.input }

        RowLayout {
            Layout.fillWidth: true

            ActionButton {
                text: ""
                glyph: AudioService.sourceMuted ? Icons.microphoneMuted : Icons.microphone
                implicitWidth: 42
                Layout.minimumWidth: 42
                Layout.preferredWidth: 42
                Layout.maximumWidth: 42
                enabled: AudioService.sourceAvailable
                onClicked: AudioService.toggleSourceMute()
            }

            StatusSlider {
                from: 0
                to: 1
                value: AudioService.sourceVolume
                enabled: AudioService.sourceAvailable
                Layout.fillWidth: true
                onMoved: AudioService.setSourceVolume(value)
            }

            Text {
                text: Math.round(AudioService.sourceVolume * 100) + "%"
                color: Theme.text
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.fontSmall
                Layout.preferredWidth: 42
                horizontalAlignment: Text.AlignRight
            }
        }

        DeviceList {
            model: AudioService.sources
            selectedDevice: AudioService.source
            glyph: Icons.microphone
            emptyDetail: AudioService.errorMessage
            onDeviceSelected: device => AudioService.selectSource(device)
        }
    }
}
