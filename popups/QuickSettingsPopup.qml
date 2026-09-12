pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import qs.components
import qs.core
import qs.services

PopupFrame {
    id: root
    required property string screenName
    property bool caffeinateExpanded: false
    readonly property var caffeinateModes: CaffeinateService.modes.concat([
        {id: "off", label: Strings.caffeinateOff, description: ""}
    ])

    function closeCaffeinate() {
        caffeinateExpanded = false;
    }

    function openCaffeinate(keyboard) {
        caffeinateExpanded = true;
        if (keyboard) {
            const index = caffeinateModes.findIndex(entry => entry.id === CaffeinateService.mode);
            modeButtons.itemAt(Math.max(0, index)).forceActiveFocus(Qt.TabFocusReason);
        }
    }

    Keys.onEscapePressed: {
        if (caffeinateExpanded) {
            closeCaffeinate();
            caffeinateTile.forceActiveFocus(Qt.BacktabFocusReason);
        } else {
            SurfaceManager.closeOn(screenName);
        }
    }
    onVisibleChanged: if (!visible) closeCaffeinate()

    component Tile: ActionButton {
        borderless: true
        glyphWidth: Metrics.iconMedium
        implicitHeight: 56
        Layout.fillWidth: true
        Layout.preferredWidth: 1
    }
    component Percentage: Text {
        color: Theme.text
        font.family: Metrics.fontFamily
        font.pixelSize: Metrics.fontSmall
        horizontalAlignment: Text.AlignRight
        Layout.preferredWidth: 42
    }

    ColumnLayout {
        width: parent.width
        spacing: Metrics.space12
        GridLayout {
            columns: 2
            columnSpacing: Metrics.space8
            rowSpacing: Metrics.space8
            Layout.fillWidth: true
            Tile {
                objectName: "quickWifi"
                text: Strings.wifi
                glyph: NetworkService.wifiEnabled ? Icons.wifi : Icons.wifiOff
                accent: NetworkService.wifiEnabled
                enabled: NetworkService.available
                Accessible.name: text + ": " + (NetworkService.wifiEnabled ? Strings.enabled : Strings.disabled)
                onClicked: NetworkService.setWifiEnabled(!NetworkService.wifiEnabled)
            }
            Tile {
                objectName: "quickBluetooth"
                text: Strings.bluetooth
                glyph: BluetoothService.enabled ? Icons.bluetooth : Icons.bluetoothOff
                accent: BluetoothService.enabled
                enabled: BluetoothService.available && BluetoothService.state !== "loading"
                Accessible.name: text + ": " + (BluetoothService.enabled ? Strings.enabled : Strings.disabled)
                onClicked: BluetoothService.setEnabled(!BluetoothService.enabled)
            }
            Tile {
                objectName: "quickMicrophone"
                text: Strings.microphone
                glyph: Icons.microphone
                glyphSlashed: AudioService.sourceMuted
                destructive: AudioService.sourceMuted
                enabled: AudioService.sourceAvailable
                Accessible.name: text + ": " + (AudioService.sourceMuted ? Strings.disabled : Strings.enabled)
                onClicked: AudioService.toggleSourceMute()
            }
            Tile {
                objectName: "quickDnd"
                text: Strings.notificationsDnd
                glyph: Icons.notification
                glyphSlashed: NotificationService.dnd
                destructive: NotificationService.dnd
                Accessible.name: text + ": " + (NotificationService.dnd ? Strings.enabled : Strings.disabled)
                onClicked: NotificationService.toggleDnd()
            }
            Tile {
                id: caffeinateTile
                objectName: "quickCaffeinate"
                text: CaffeinateService.label
                glyph: Icons.coffee
                accent: CaffeinateService.active
                hoverEnabled: true
                Accessible.name: text + ": " + (CaffeinateService.active ? Strings.enabled : Strings.disabled)
                Accessible.description: Strings.caffeinateChooseMode
                Keys.onDownPressed: root.openCaffeinate(true)
                Keys.onReturnPressed: clicked()
                Keys.onEnterPressed: clicked()
                onClicked: {
                    if (root.caffeinateExpanded) root.closeCaffeinate();
                    else root.openCaffeinate(!hovered);
                }
            }
            Tile {
                objectName: "quickScreenshot"
                text: Strings.screenshot
                glyph: Icons.screenshot
                enabled: !LockService.locked && !LockService.releasing
                Accessible.name: text
                onClicked: ScreenshotService.begin("region", root.screenName)
            }
        }
        RevealSection {
            id: modeList
            objectName: "caffeinateModes"
            revealed: root.caffeinateExpanded
            Layout.fillWidth: true

            FocusScope {
                id: modeFocus
                width: parent.width
                height: modeColumn.implicitHeight
                ColumnLayout {
                    id: modeColumn
                    width: parent.width
                    spacing: Metrics.space4
                    Repeater {
                        id: modeButtons
                        model: root.caffeinateModes
                        ActionButton {
                            id: modeButton
                            required property var modelData
                            required property int index
                            objectName: "caffeinateMode-" + modelData.id
                            text: modelData.label
                            accent: CaffeinateService.mode === modelData.id
                            borderless: true
                            Layout.fillWidth: true
                            implicitHeight: modeContent.implicitHeight + Metrics.space16
                            Accessible.role: Accessible.RadioButton
                            Accessible.checked: accent
                            Accessible.name: text
                            Accessible.description: modelData.description
                            contentItem: RowLayout {
                                id: modeContent
                                spacing: Metrics.space8
                                Text {
                                    text: modeButton.text
                                    color: modeButton.accent ? Theme.accent : Theme.text
                                    font.family: Metrics.fontFamily
                                    font.pixelSize: Metrics.fontBody
                                    font.weight: Font.DemiBold
                                    font.underline: modeButton.visualFocus
                                    Layout.fillWidth: true
                                    wrapMode: Text.Wrap
                                }
                                Text {
                                    text: Icons.check
                                    opacity: modeButton.accent ? 1 : 0
                                    color: Theme.accent
                                    font.family: Metrics.fontFamily
                                    font.pixelSize: Metrics.iconMedium
                                }
                            }
                            Keys.onDownPressed: modeButtons.itemAt((index + 1) % modeButtons.count).forceActiveFocus(Qt.TabFocusReason)
                            Keys.onUpPressed: {
                                if (index === 0) caffeinateTile.forceActiveFocus(Qt.BacktabFocusReason);
                                else modeButtons.itemAt(index - 1).forceActiveFocus(Qt.BacktabFocusReason);
                            }
                            Keys.onReturnPressed: clicked()
                            Keys.onEnterPressed: clicked()
                            onClicked: {
                                const focusReason = modeButton.visualFocus
                                    ? Qt.BacktabFocusReason : Qt.MouseFocusReason;
                                CaffeinateService.setMode(modelData.id);
                                root.closeCaffeinate();
                                caffeinateTile.forceActiveFocus(focusReason);
                            }
                        }
                    }
                }
            }
        }
        RowLayout {
            Layout.fillWidth: true
            ActionButton {
                objectName: "quickMute"
                glyph: Icons.volumeHigh
                glyphSlashed: AudioService.muted
                destructive: AudioService.muted
                borderless: true
                implicitWidth: 42
                enabled: AudioService.available
                Accessible.name: Strings.volume
                onClicked: AudioService.toggleMute()
            }
            StatusSlider {
                objectName: "quickVolume"
                from: 0
                to: 1
                value: AudioService.volume
                enabled: AudioService.available
                Layout.fillWidth: true
                Accessible.name: Strings.volume
                onMoved: AudioService.setVolume(value)
            }
            Percentage { text: Math.round(AudioService.volume * 100) + "%" }
        }
        RowLayout {
            Layout.fillWidth: true
            Item {
                Layout.preferredWidth: 42
                implicitHeight: brightnessIcon.implicitHeight

                Text {
                    id: brightnessIcon
                    anchors.centerIn: parent
                    text: Icons.brightness
                    color: Theme.text
                    font.family: Metrics.fontFamily
                    font.pixelSize: Metrics.iconMedium
                }
            }
            StatusSlider {
                objectName: "quickBrightness"
                from: 1
                to: 100
                stepSize: 0
                value: BrightnessService.sliderPercentage
                enabled: BrightnessService.available
                Layout.fillWidth: true
                Accessible.name: Strings.brightness
                onMoved: BrightnessService.setPercentage(value)
            }
            Percentage { text: Math.round(BrightnessService.percentage) + "%" }
        }
        Text {
            readonly property string errors: [AudioService.errorMessage, BrightnessService.errorMessage,
                NetworkService.errorMessage, BluetoothService.errorMessage,
                CaffeinateService.errorMessage, ScreenshotService.errorMessage].filter(value => !!value).join("\n")
            visible: errors.length > 0
            text: errors
            color: Theme.warning
            font.family: Metrics.fontFamily
            font.pixelSize: Metrics.fontSmall
            wrapMode: Text.Wrap
            Layout.fillWidth: true
        }
    }
}
