pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.components
import qs.core
import qs.services

ColumnLayout {
    id: root

    property bool input: false
    property bool expanded: false
    readonly property bool available: input ? AudioService.sourceAvailable : AudioService.available
    readonly property bool muted: input ? AudioService.sourceMuted : AudioService.muted
    readonly property real level: input ? AudioService.sourceVolume : AudioService.volume
    readonly property real displayedLevel: muted ? 0 : level
    readonly property var devices: input ? AudioService.sources : AudioService.sinks
    readonly property var selectedDevice: input ? AudioService.source : AudioService.sink
    readonly property string label: input ? Strings.microphone : Strings.volume
    readonly property string prefix: input ? "quickInput" : "quickOutput"

    spacing: Metrics.space12

    function openDevices(keyboard) {
        if (!visible)
            return;
        expanded = true;
        if (keyboard && deviceLoader.item)
            deviceLoader.item.forceActiveFocus(Qt.TabFocusReason);
    }

    function closeDevices(focusReason) {
        holdTimer.stop();
        expanded = false;
        if (focusReason !== undefined)
            muteButton.forceActiveFocus(focusReason);
    }

    function selectDevice(device, focusReason) {
        if (input) AudioService.selectSource(device);
        else AudioService.selectSink(device);
        closeDevices(focusReason);
    }

    onVisibleChanged: if (!visible) closeDevices()
    onAvailableChanged: if (!available) holdTimer.stop()

    RowLayout {
        Layout.fillWidth: true

        ActionButton {
            id: muteButton
            property bool holdHandled: false
            objectName: root.input ? "quickMicrophone" : "quickMute"
            glyph: root.input ? Icons.microphone : Icons.volumeHigh
            glyphSlashed: root.muted
            destructive: root.muted
            borderless: true
            implicitWidth: 42
            enabled: root.available
            Accessible.name: root.label + ": " + (root.muted ? Strings.disabled : Strings.enabled)
            Accessible.description: Strings.audioDeviceHoldHint
            Keys.onDownPressed: root.openDevices(true)
            Keys.onReturnPressed: { holdHandled = false; clicked(); }
            Keys.onEnterPressed: { holdHandled = false; clicked(); }
            onPressed: holdHandled = false
            onClicked: {
                if (holdHandled) return;
                if (root.input) AudioService.toggleSourceMute();
                else AudioService.toggleMute();
            }

            TapHandler {
                // Keep the button's short click; movement cancels the hold.
                acceptedButtons: Qt.LeftButton
                enabled: root.visible
                gesturePolicy: TapHandler.DragThreshold
                // Own the one-shot timer so closing or hiding the panel can
                // cancel a pending hold even before the pointer is released.
                longPressThreshold: 0
                onPressedChanged: {
                    if (pressed && root.visible && root.available) holdTimer.restart();
                    else holdTimer.stop();
                }
            }
            Timer {
                id: holdTimer
                interval: Motion.audioDeviceHold
                onTriggered: {
                    muteButton.holdHandled = true;
                    root.openDevices(false);
                }
            }
        }

        StatusSlider {
            id: slider
            objectName: root.input ? "quickMicrophoneVolume" : "quickVolume"
            from: 0
            to: 1
            value: root.displayedLevel
            enabled: root.available
            Layout.fillWidth: true
            Accessible.name: root.label
            onMoved: {
                if (root.input) AudioService.setSourceVolume(value);
                else AudioService.setVolume(value);
            }
        }

        Text {
            text: Math.round(root.displayedLevel * 100) + "%"
            color: Theme.text
            font.family: Metrics.fontFamily
            font.pixelSize: Metrics.fontSmall
            horizontalAlignment: Text.AlignRight
            Layout.preferredWidth: 42
        }
    }

    RevealSection {
        id: reveal
        objectName: root.prefix + "Reveal"
        revealed: root.expanded
        Layout.fillWidth: true

        Loader {
            id: deviceLoader
            objectName: root.prefix + "DevicesLoader"
            active: root.expanded || reveal.progress > 0
            width: parent.width
            height: item ? item.implicitHeight : 0

            sourceComponent: ListView {
                id: deviceList
                objectName: root.prefix + "Devices"
                model: root.devices
                clip: true
                spacing: Metrics.space4
                implicitHeight: Math.max(1, Math.min(count, 3)) * Metrics.popupRowHeight
                    + Math.max(0, Math.min(count, 3) - 1) * spacing
                activeFocusOnTab: true
                keyNavigationEnabled: true
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar {}

                onActiveFocusChanged: {
                    if (activeFocus) {
                        currentIndex = Math.max(0, root.devices.indexOf(root.selectedDevice));
                        positionViewAtIndex(currentIndex, ListView.Contain);
                    }
                }
                Keys.onReturnPressed: if (currentItem) currentItem.choose(Qt.BacktabFocusReason)
                Keys.onEnterPressed: if (currentItem) currentItem.choose(Qt.BacktabFocusReason)
                Keys.onSpacePressed: if (currentItem) currentItem.choose(Qt.BacktabFocusReason)

                delegate: ActionButton {
                    id: deviceButton
                    required property var modelData
                    required property int index
                    readonly property bool keyboardFocus: deviceList.activeFocus && ListView.isCurrentItem
                    objectName: root.prefix + "Device-" + index
                    text: modelData.description || modelData.nickname || modelData.name
                    width: ListView.view.width
                    height: Metrics.popupRowHeight
                    accent: modelData === root.selectedDevice
                    borderless: true
                    focusPolicy: Qt.NoFocus
                    Accessible.role: Accessible.RadioButton
                    Accessible.name: text
                    Accessible.checked: accent
                    ToolTip.text: text
                    ToolTip.visible: hovered && deviceName.truncated
                    ToolTip.delay: Motion.audioDeviceHold

                    function choose(focusReason) {
                        root.selectDevice(modelData, focusReason);
                    }

                    contentItem: RowLayout {
                        spacing: Metrics.space8
                        Text {
                            text: root.input ? Icons.microphone : Icons.volumeHigh
                            color: deviceButton.accent ? Theme.accent : Theme.subtext0
                            font.family: Metrics.fontFamily
                            font.pixelSize: Metrics.iconMedium
                        }
                        Text {
                            id: deviceName
                            text: deviceButton.text
                            textFormat: Text.PlainText
                            color: deviceButton.accent ? Theme.accent : Theme.text
                            font.family: Metrics.fontFamily
                            font.pixelSize: Metrics.fontSmall
                            font.underline: deviceButton.keyboardFocus
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                        Text {
                            text: Icons.check
                            opacity: deviceButton.accent ? 1 : 0
                            color: Theme.accent
                            font.family: Metrics.fontFamily
                            font.pixelSize: Metrics.iconSmall
                        }
                    }
                    onClicked: choose(Qt.MouseFocusReason)
                }

                Text {
                    anchors.fill: parent
                    visible: deviceList.count === 0
                    text: root.input ? Strings.noAudioInputs : Strings.noAudioOutputs
                    color: Theme.subtext0
                    font.family: Metrics.fontFamily
                    font.pixelSize: Metrics.fontSmall
                    verticalAlignment: Text.AlignVCenter
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                }
            }
        }
    }
}
