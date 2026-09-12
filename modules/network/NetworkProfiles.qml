pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.components
import qs.core
import qs.services

ColumnLayout {
    id: root
    property bool vpn: false
    spacing: Metrics.space12
    SearchField {
        id: search
        objectName: "networkProfileSearch"
        placeholderText: root.vpn ? Strings.networkVpnSearch : Strings.networkSearch
        Layout.fillWidth: true
    }
    ListView {
        id: list
        objectName: root.vpn ? "networkVpnList" : "networkSavedList"
        model: (root.vpn ? NetworkService.vpnProfiles : NetworkService.savedProfiles).filter(profile =>
            (profile.name || "").toLocaleLowerCase().indexOf(search.text.trim().toLocaleLowerCase()) >= 0)
        Layout.fillWidth: true
        Layout.fillHeight: true
        spacing: Metrics.space8
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        activeFocusOnTab: count > 0
        keyNavigationEnabled: true
        ScrollBar.vertical: ScrollBar {}
        onActiveFocusChanged: { if (activeFocus && currentIndex < 0 && count > 0) currentIndex = 0; }
        Keys.onReturnPressed: { if (currentItem) currentItem.edit(); }
        Keys.onEnterPressed: { if (currentItem) currentItem.edit(); }
        delegate: Rectangle {
            id: row
            required property var modelData
            required property int index
            width: list.width - (list.ScrollBar.vertical.visible ? Metrics.space12 : 0)
            height: Metrics.popupRowHeight + Metrics.space16
            radius: Metrics.space12
            border.width: Metrics.borderWidth
            border.color: list.activeFocus && ListView.isCurrentItem ? Theme.accent : Theme.withAlpha(Theme.surface1, 0.7)
            color: Theme.controlBackground(Theme.text, hover.hovered)
            HoverHandler { id: hover }
            function edit() { if (!NetworkService.settingsBusy) NetworkService.editProfile(modelData.uuid); }
            RowLayout {
                anchors.fill: parent
                anchors.margins: Metrics.space12
                spacing: Metrics.space12
                Text { text: root.vpn ? Icons.lock : Icons.wifi; color: Theme.accent; font.family: Metrics.fontFamily; font.pixelSize: Metrics.iconMedium }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Metrics.space4
                    Text {
                        text: row.modelData.name
                        textFormat: Text.PlainText
                        color: Theme.text
                        font.family: Metrics.fontFamily
                        font.pixelSize: Metrics.fontBody
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                    Text {
                        text: root.vpn ? (row.modelData.kind === "openvpn" ? "OpenVPN" : row.modelData.kind) + " · "
                            + (row.modelData.state === 2 ? Strings.connected : row.modelData.state === 1 ? Strings.connecting
                                : row.modelData.state === 3 ? Strings.networkDisconnecting : Strings.networkNotConnected)
                            : row.modelData.connected ? Strings.connected : Strings.remembered
                        textFormat: Text.PlainText
                        color: Theme.subtext0
                        font.family: Metrics.fontFamily
                        font.pixelSize: Metrics.fontSmall
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                }
                ActionButton {
                    objectName: "networkProfileDetails" + row.index
                    glyph: Icons.settings
                    Accessible.name: Strings.networkConnectionSettings + ": " + row.modelData.name
                    borderless: true
                    enabled: !NetworkService.settingsBusy
                    onClicked: row.edit()
                }
                ActionButton {
                    objectName: "networkVpnToggle" + row.index
                    visible: root.vpn
                    text: row.modelData.state === 2 || row.modelData.state === 1 ? Strings.networkDisconnect : Strings.connect
                    accent: row.modelData.state === 2
                    enabled: !NetworkService.settingsBusy && row.modelData.state !== 3
                    onClicked: NetworkService.toggleVpn(row.modelData.uuid)
                }
            }
        }
        EmptyState {
            anchors.centerIn: parent
            width: Math.min(parent.width - Metrics.space24, 380)
            visible: list.count === 0
            icon: root.vpn ? Icons.lock : Icons.wifi
            title: root.vpn && NetworkService.vpnLoading ? Strings.networkLoading : root.vpn ? Strings.networkNoVpn : Strings.networkNoSaved
            detail: root.vpn ? Strings.networkNoVpnHint : ""
        }
    }
}
