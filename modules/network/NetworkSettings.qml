pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.components
import qs.core
import qs.services

Item {
    id: root
    required property string screenName
    property bool windowVisible: true
    property string section: "wifi"
    property bool savedWifi: false
    property bool addingVpn: false
    property var pendingAction: null
    readonly property bool editing: !!NetworkService.editingUuid
    readonly property bool dirty: editing && body.item && body.item.dirty === true
    readonly property bool scanning: windowVisible && section === "wifi" && !savedWifi && !editing
        && !pendingAction && NetworkService.wifiEnabled
    signal closeRequested()
    onScanningChanged: NetworkService.settingsScanning = scanning
    Component.onCompleted: { NetworkService.settingsScanning = scanning; wifiNav.forceActiveFocus(); }
    Component.onDestruction: NetworkService.settingsScanning = false
    function navigate(action) {
        if (NetworkService.settingsBusy && NetworkService.settingsOperation !== "load") return;
        if (dirty || (addingVpn && Object.keys(NetworkService.vpnPreview).length > 0)) {
            pendingAction = action;
            Qt.callLater(() => keepEditing.forceActiveFocus());
        } else action();
    }
    function requestClose() {
        if (NetworkService.settingsBusy) root.closeRequested();
        else navigate(() => root.closeRequested());
    }
    function switchSection(value) {
        navigate(() => { NetworkService.closeProfile(); NetworkService.cancelVpn(); addingVpn = false; section = value; });
    }
    function back() { navigate(() => { NetworkService.closeProfile(); NetworkService.cancelVpn(); addingVpn = false; }); }
    Keys.onEscapePressed: event => {
        if (pendingAction) pendingAction = null;
        else if (editing || addingVpn) back();
        else requestClose();
        event.accepted = true;
    }
    Connections { target: NetworkService; function onVpnAdded() { root.addingVpn = false; } }
    RowLayout {
        anchors.fill: parent
        enabled: root.pendingAction === null
        spacing: 0
        ColumnLayout {
            Layout.preferredWidth: Metrics.networkSidebarWidth
            Layout.minimumWidth: Metrics.networkSidebarWidth
            Layout.maximumWidth: Metrics.networkSidebarWidth
            Layout.fillHeight: true
            Layout.margins: Metrics.space12
            spacing: Metrics.space8
            ActionButton {
                id: wifiNav
                objectName: "networkWifiSection"
                text: Strings.wifi
                glyph: Icons.wifi
                accent: root.section === "wifi"
                borderless: true
                Layout.fillWidth: true
                onClicked: root.switchSection("wifi")
            }
            ActionButton {
                objectName: "networkVpnSection"
                text: Strings.networkVpn
                glyph: Icons.lock
                accent: root.section === "vpn"
                borderless: true
                Layout.fillWidth: true
                onClicked: root.switchSection("vpn")
            }
            Item { Layout.fillHeight: true }
        }
        Rectangle { Layout.fillHeight: true; implicitWidth: Metrics.borderWidth; color: Theme.withAlpha(Theme.surface1, 0.65) }
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.margins: Metrics.space24
            spacing: Metrics.space16
            RowLayout {
                Layout.fillWidth: true
                ActionButton {
                    objectName: "networkSettingsBack"
                    text: "‹"
                    Accessible.name: Strings.networkOverview
                    visible: root.editing || root.addingVpn
                    onClicked: root.back()
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Metrics.space4
                    Text {
                        text: root.editing && NetworkService.profileSettings.name ? NetworkService.profileSettings.name
                            : root.addingVpn ? Strings.networkAddVpn : root.section === "wifi" ? Strings.wifi : Strings.networkVpn
                        textFormat: Text.PlainText
                        color: Theme.text
                        font.family: Metrics.fontFamily
                        font.pixelSize: Metrics.iconLarge
                        font.weight: Font.DemiBold
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                    Text {
                        visible: !root.editing && !root.addingVpn
                        text: root.section === "wifi" ? Strings.networkWifiHint : Strings.networkVpnHint
                        color: Theme.subtext0
                        font.family: Metrics.fontFamily
                        font.pixelSize: Metrics.fontSmall
                        wrapMode: Text.Wrap
                        Layout.fillWidth: true
                    }
                }
            }
            Loader {
                id: body
                objectName: "networkSettingsBody"
                Layout.fillWidth: true
                Layout.fillHeight: true
                active: !root.editing || Object.keys(NetworkService.profileSettings).length > 0
                sourceComponent: root.editing ? (Object.keys(NetworkService.profileSettings).length > 0 ? editor : null)
                    : root.addingVpn ? vpnImport : overview
            }
            Text {
                visible: root.editing && NetworkService.settingsOperation === "load"
                text: Strings.networkLoading
                color: Theme.subtext0
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.fontBody
            }
            Text {
                objectName: "networkSettingsError"
                text: NetworkService.settingsError || (root.section === "vpn" ? NetworkService.vpnError : "")
                visible: text.length > 0
                textFormat: Text.PlainText
                color: Theme.error
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.fontSmall
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
        }
    }
    Component { id: editor; NetworkProfileEditor { initial: NetworkService.profileSettings; maximumHeight: body.height } }
    Component { id: vpnImport; NetworkVpnImport {} }
    Component {
        id: overview
        ColumnLayout {
            spacing: Metrics.space16
            ToggleRow {
                visible: root.section === "wifi"
                title: Strings.wifi
                checked: NetworkService.wifiEnabled
                enabled: NetworkService.available
                Layout.fillWidth: true
                onToggled: value => NetworkService.setWifiEnabled(value)
            }
            RowLayout {
                visible: root.section === "wifi"
                Layout.fillWidth: true
                ActionButton {
                    objectName: "networkNearbyTab"
                    text: Strings.networkNearby
                    accent: !root.savedWifi
                    borderless: true
                    onClicked: root.savedWifi = false
                }
                ActionButton {
                    objectName: "networkSavedTab"
                    text: Strings.networkSaved
                    accent: root.savedWifi
                    borderless: true
                    onClicked: root.savedWifi = true
                }
                Item { Layout.fillWidth: true }
            }
            RowLayout {
                visible: root.section === "vpn"
                Layout.fillWidth: true
                ActionButton {
                    objectName: "networkAddVpn"
                    text: Strings.networkAddVpn
                    accent: true
                    enabled: !NetworkService.settingsBusy
                    onClicked: { NetworkService.cancelVpn(); root.addingVpn = true; }
                }
                Item { Layout.fillWidth: true }
                ActionButton {
                    text: Strings.networkRetry
                    visible: !!NetworkService.vpnError
                    enabled: !NetworkService.settingsBusy
                    onClicked: NetworkService.refreshVpn()
                }
            }
            Loader {
                id: overviewList
                Layout.fillWidth: true
                Layout.fillHeight: true
                sourceComponent: root.section === "wifi" && !root.savedWifi ? nearby : saved
            }
            Component {
                id: nearby
                NetworkNearby {
                    maximumListHeight: Math.max(Metrics.popupRowHeight * 2, overviewList.height
                        - (passwordNetwork ? Metrics.popupRowHeight * 3 : Metrics.popupRowHeight)
                        - (NetworkService.errorMessage ? Metrics.popupRowHeight : 0))
                }
            }
            Component { id: saved; NetworkProfiles { vpn: root.section === "vpn" } }
        }
    }
    Rectangle {
        anchors.fill: parent
        visible: root.pendingAction !== null
        color: Theme.withAlpha(Theme.base, Settings.surfaceOpacity)
        MouseArea { anchors.fill: parent }
        ColumnLayout {
            anchors.centerIn: parent
            width: Math.min(parent.width - Metrics.space24 * 2, 420)
            spacing: Metrics.space16
            SectionTitle { text: Strings.networkDiscardTitle; Layout.fillWidth: true; wrapMode: Text.Wrap }
            Text {
                text: Strings.networkDiscardHint
                color: Theme.subtext0
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.fontBody
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            ActionButton {
                id: keepEditing
                objectName: "networkKeepEditing"
                text: Strings.networkKeepEditing
                accent: true
                Layout.fillWidth: true
                onClicked: { root.pendingAction = null; wifiNav.forceActiveFocus(); }
            }
            ActionButton {
                objectName: "networkDiscard"
                text: Strings.networkDiscard
                destructive: true
                Layout.fillWidth: true
                onClicked: { const action = root.pendingAction; root.pendingAction = null; if (action) action(); }
            }
        }
    }
}
