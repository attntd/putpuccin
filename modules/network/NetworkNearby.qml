pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell.Networking
import qs.components
import qs.core
import qs.services

ColumnLayout {
    id: root
    property var passwordNetwork: null
    onPasswordNetworkChanged: password.clear()
    property real maximumListHeight: 5 * Metrics.popupRowHeight + 4 * Metrics.space6
    readonly property var sortedNetworks: NetworkService.networks.slice().sort((a, b) =>
        a.connected !== b.connected ? (a.connected ? -1 : 1)
        : a.known !== b.known ? (a.known ? -1 : 1) : b.signalStrength - a.signalStrength)
    function signalIcon(strength) { return strength >= 0.67 ? Icons.signalStrong : strength >= 0.34 ? Icons.signalMedium : Icons.signalWeak; }
            spacing: Metrics.space8
            SectionTitle { text: Strings.availableNetworks }

            ListView {
                id: networkList
                objectName: "networkNearbyList"
                model: root.sortedNetworks
                spacing: Metrics.space6
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                activeFocusOnTab: count > 0
                keyNavigationEnabled: true
                Layout.fillWidth: true
                Layout.preferredHeight: count === 0 ? 92
                    : Math.min(count * Metrics.popupRowHeight + Math.max(0, count - 1) * spacing, root.maximumListHeight)
                ScrollBar.vertical: ScrollBar {}

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
                    id: networkDelegate
                    required property var modelData
                    required property int index
                    width: ListView.view.width
                    height: Metrics.popupRowHeight
                    radius: 10
                    color: modelData.connected || (networkList.activeFocus && ListView.isCurrentItem)
                        ? Theme.controlBackground(Theme.accent, false, false, true)
                        : Theme.controlBackground(Theme.text, networkMouse.containsMouse)

                    function activate() {
                        if (networkDelegate.modelData.connected || networkDelegate.modelData.known
                                || networkDelegate.modelData.security === WifiSecurityType.Open
                                || networkDelegate.modelData.security === WifiSecurityType.Owe) {
                            root.passwordNetwork = null;
                            NetworkService.connectNetwork(networkDelegate.modelData, "");
                        } else if (NetworkService.supportsPsk(networkDelegate.modelData)) {
                            root.passwordNetwork = networkDelegate.modelData;
                            password.forceActiveFocus();
                        } else {
                            root.passwordNetwork = null;
                            NetworkService.connectNetwork(networkDelegate.modelData, "");
                        }
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.margins: Metrics.space8
                        anchors.rightMargin: Metrics.space8
                            + (networkList.ScrollBar.vertical.visible ? 8 : 0)

                        Text {
                            text: root.signalIcon(networkDelegate.modelData.signalStrength)
                            color: networkDelegate.modelData.connected ? Theme.accent : Theme.subtext0
                            font.family: Metrics.fontFamily
                            font.pixelSize: Metrics.iconMedium
                        }
                        Text {
                            textFormat: Text.PlainText
                            text: networkDelegate.modelData.name
                            color: Theme.text
                            font.family: Metrics.fontFamily
                            font.pixelSize: Metrics.fontSmall
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                            Layout.minimumWidth: 0
                        }

                        Text {
                            visible: networkDelegate.modelData.security !== WifiSecurityType.Open
                            text: Icons.lock
                            color: Theme.overlay1
                            font.family: Metrics.fontFamily
                            font.pixelSize: Metrics.iconSmall
                        }

                        Text {
                            text: networkDelegate.modelData.connected ? Strings.connected
                                : networkDelegate.modelData.stateChanging ? Strings.connecting
                                : networkDelegate.modelData.known ? Strings.remembered : ""
                            visible: text.length > 0
                            color: networkDelegate.modelData.connected ? Theme.accent : Theme.subtext0
                            font.family: Metrics.fontFamily
                            font.pixelSize: 10
                            horizontalAlignment: Text.AlignRight
                        }
                    }

                    MouseArea {
                        id: networkMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        enabled: !networkDelegate.modelData.stateChanging
                        onClicked: {
                            networkList.currentIndex = networkDelegate.index;
                            networkDelegate.activate();
                        }
                    }
                }

                EmptyState {
                    anchors.centerIn: parent
                    width: parent.width - 30
                    visible: networkList.count === 0
                    icon: NetworkService.wifiEnabled ? Icons.wifi : Icons.wifiOff
                    title: !NetworkService.available ? Strings.unavailable
                        : !NetworkService.wifiEnabled ? Strings.wifiDisabled : Strings.noNetworks
                    detail: NetworkService.errorMessage
                }
            }

            Rectangle {
                visible: root.passwordNetwork !== null
                Layout.fillWidth: true
                implicitHeight: passwordColumn.implicitHeight + Metrics.space16
                color: Theme.controlBackground(Theme.surface0)
                radius: 10

                ColumnLayout {
                    id: passwordColumn
                    anchors.fill: parent
                    anchors.margins: Metrics.space8
                    spacing: Metrics.space8

                    Text {
                        textFormat: Text.PlainText
                        text: root.passwordNetwork ? Strings.passwordFor(root.passwordNetwork.name) : ""
                        color: Theme.text
                        font.family: Metrics.fontFamily
                        font.pixelSize: Metrics.fontSmall
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        TextField {
                            id: password
                            objectName: "networkPassword"
                            implicitHeight: connectButton.implicitHeight
                            echoMode: TextInput.Password
                            maximumLength: 64
                            color: Theme.text
                            font.family: Metrics.fontFamily
                            font.pixelSize: Metrics.fontBody
                            leftPadding: Metrics.space12
                            rightPadding: Metrics.space12
                            Layout.fillWidth: true
                            onAccepted: if (connectButton.enabled) connectButton.clicked()
                            background: Rectangle {
                                radius: 8
                                color: Theme.controlBackground(Theme.mantle)
                                border.width: 1
                                border.color: Theme.surface1
                            }
                        }
                        ActionButton {
                            id: connectButton
                            objectName: "networkConnect"
                            borderless: true
                            text: Strings.connect
                            accent: true
                            enabled: NetworkService.validPsk(password.text)
                            onClicked: {
                                NetworkService.connectNetwork(root.passwordNetwork, password.text);
                                password.text = "";
                                root.passwordNetwork = null;
                            }
                        }
                    }
                }
            }

            Text {
                visible: NetworkService.errorMessage.length > 0
                text: NetworkService.errorMessage
                color: Theme.error
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.fontSmall
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }

        }
