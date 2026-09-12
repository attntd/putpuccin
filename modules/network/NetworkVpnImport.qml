pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import qs.components
import qs.core
import qs.services

ColumnLayout {
    id: root
    property string type: "wireguard"
    readonly property bool prepared: Object.keys(NetworkService.vpnPreview).length > 0
    spacing: Metrics.space16
    Text {
        text: Strings.networkVpnImportHint
        color: Theme.subtext0
        font.family: Metrics.fontFamily
        font.pixelSize: Metrics.fontBody
        wrapMode: Text.Wrap
        Layout.fillWidth: true
    }
    NetworkChoice {
        objectName: "networkVpnType"
        title: Strings.networkVpnType
        value: root.type
        options: [{value: "wireguard", label: "WireGuard"}, {value: "openvpn", label: "OpenVPN"}]
        enabled: !NetworkService.settingsBusy
        Layout.fillWidth: true
        onSelected: value => { NetworkService.cancelVpn(); root.type = value; }
    }
    Text {
        visible: root.type === "openvpn" && !NetworkService.openVpnAvailable
        text: Strings.networkVpnPluginMissing
        color: Theme.subtext0
        font.family: Metrics.fontFamily
        font.pixelSize: Metrics.fontSmall
        wrapMode: Text.Wrap
        Layout.fillWidth: true
    }
    ActionButton {
        objectName: "networkVpnChooseFile"
        text: Strings.networkVpnFile
        enabled: !NetworkService.settingsBusy && (root.type !== "openvpn" || NetworkService.openVpnAvailable)
        Layout.fillWidth: true
        onClicked: picker.open()
    }
    Text {
        visible: root.prepared
        text: Strings.networkSelectedFile.arg(NetworkService.vpnPreview.fileName || "")
        textFormat: Text.PlainText
        color: Theme.subtext0
        font.family: Metrics.fontFamily
        font.pixelSize: Metrics.fontSmall
        wrapMode: Text.WrapAnywhere
        Layout.fillWidth: true
    }
    NetworkField {
        id: name
        objectName: "networkVpnName"
        visible: root.prepared
        title: Strings.networkProfileName
        text: NetworkService.vpnPreview.name || ""
        input.maximumLength: 128
        enabled: !NetworkService.settingsBusy
        Layout.fillWidth: true
    }
    Item { Layout.fillHeight: true }
    ActionButton {
        objectName: "networkVpnImportSave"
        text: NetworkService.settingsBusy ? Strings.networkSaving : Strings.networkVpnAdd
        accent: true
        visible: root.prepared
        enabled: !NetworkService.settingsBusy && name.text.trim().length > 0
        Layout.fillWidth: true
        onClicked: NetworkService.addVpn(name.text)
    }
    FileDialog {
        id: picker
        title: Strings.networkVpnFileTitle
        fileMode: FileDialog.OpenFile
        nameFilters: [root.type === "wireguard" ? Strings.networkWireguardFilter : Strings.networkOpenvpnFilter]
        onAccepted: NetworkService.prepareVpn(selectedFile, root.type)
    }
}
