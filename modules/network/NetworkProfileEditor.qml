pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.components
import qs.core
import qs.services

ColumnLayout {
    id: root
    required property var initial
    property real maximumHeight: Metrics.networkSettingsHeight
    property var draft: ({name: "", type: "", autoconnect: false, hidden: false, metered: 0,
        ipv4: {method: "auto", addresses: "", gateway: "", dns: "", autoDns: true},
        ipv6: {method: "auto", addresses: "", gateway: "", dns: "", autoDns: true}})
    property int tab: 0
    property bool confirmingForget: false
    readonly property bool dirty: JSON.stringify(draft) !== JSON.stringify(initial)
    readonly property bool busy: NetworkService.settingsBusy
    readonly property string family: tab === 1 ? "ipv4" : "ipv6"
    spacing: Metrics.space8
    Component.onCompleted: {
        // The form owns a snapshot. Clearing the service while closing must
        // neither erase the user's draft nor reevaluate fields against {}.
        initial = JSON.parse(JSON.stringify(initial));
        if (initial.ipv4 && initial.ipv6) draft = JSON.parse(JSON.stringify(initial));
    }

    function change(key, value) {
        const next = Object.assign({}, draft); next[key] = value; draft = next;
    }
    function changeIp(key, value) {
        const ip = Object.assign({}, draft[family]); ip[key] = value;
        change(family, ip);
    }
    function methodOptions() {
        const options = [{value: "auto", label: root.family === "ipv4" ? Strings.networkDhcp : Strings.networkAutomatic},
            {value: "manual", label: Strings.networkManual}, {value: "link-local", label: Strings.networkLinkLocal},
            {value: "disabled", label: Strings.networkIpDisabled}];
        const method = root.draft[root.family].method;
        if (!options.some(option => option.value === method))
            options.push({value: method, label: Strings.networkKeepMethod.arg(method)});
        return options;
    }

    RowLayout {
        visible: !root.confirmingForget
        Layout.fillWidth: true
        Repeater {
            model: [Strings.networkGeneral, "IPv4", "IPv6"]
            ActionButton {
                required property string modelData
                required property int index
                objectName: "networkTab" + index
                text: modelData
                accent: root.tab === index
                borderless: true
                Layout.fillWidth: true
                enabled: !root.busy
                onClicked: { root.tab = index; form.contentY = 0; }
            }
        }
    }
    Flickable {
        id: form
        objectName: "networkForm"
        visible: !root.confirmingForget
        Layout.fillWidth: true
        Layout.preferredHeight: Math.min(formContent.implicitHeight, Math.max(Metrics.popupRowHeight,
            root.maximumHeight - controls.implicitHeight - Metrics.popupRowHeight - 2 * root.spacing))
        contentWidth: width
        contentHeight: formContent.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar {}
        function ensureItemVisible(item) {
            const top = item.mapToItem(contentItem, 0, 0).y;
            if (top < contentY) contentY = top;
            else if (top + item.height > contentY + height) contentY = Math.min(contentHeight - height, top + item.height - height);
        }
        ColumnLayout {
            id: formContent
            width: form.width - (form.ScrollBar.vertical.visible ? Metrics.space12 : 0)
            spacing: Metrics.space8
            enabled: !root.busy
            ColumnLayout {
                visible: root.tab === 0
                Layout.fillWidth: true
                spacing: Metrics.space8
                NetworkField {
                    objectName: "networkName"
                    title: Strings.networkProfileName
                    text: root.draft.name
                    input.maximumLength: 128
                    Layout.fillWidth: true
                    onEdited: value => root.change("name", value)
                }
                ToggleRow {
                    objectName: "networkAutoconnect"
                    visible: root.initial.type !== "vpn"
                    title: Strings.networkAutoConnect
                    checked: root.draft.autoconnect
                    Layout.fillWidth: true
                    onToggled: value => root.change("autoconnect", value)
                }
                ToggleRow {
                    objectName: "networkHidden"
                    visible: root.initial.type === "802-11-wireless"
                    title: Strings.networkHidden
                    checked: root.draft.hidden
                    Layout.fillWidth: true
                    onToggled: value => root.change("hidden", value)
                }
                NetworkChoice {
                    objectName: "networkMetered"
                    title: Strings.networkMetered
                    value: root.draft.metered
                    options: [{value: 0, label: Strings.networkAutomatic}, {value: 1, label: Strings.networkYes}, {value: 2, label: Strings.networkNo}]
                    Layout.fillWidth: true
                    onSelected: value => root.change("metered", value)
                }
            }
            ColumnLayout {
                visible: root.tab !== 0
                Layout.fillWidth: true
                spacing: Metrics.space8
                NetworkChoice {
                    objectName: "networkIpMethod"
                    title: Strings.networkIpMethod
                    value: root.draft[root.family].method
                    options: root.methodOptions()
                    Layout.fillWidth: true
                    onSelected: value => root.changeIp("method", value)
                }
                NetworkField {
                    objectName: "networkAddresses"
                    visible: root.draft[root.family].method === "manual"
                    title: Strings.networkAddresses
                    text: root.draft[root.family].addresses
                    placeholderText: root.family === "ipv4" ? Strings.networkAddress4Hint : Strings.networkAddress6Hint
                    Layout.fillWidth: true
                    onEdited: value => root.changeIp("addresses", value)
                }
                NetworkField {
                    objectName: "networkGateway"
                    visible: root.draft[root.family].method === "manual"
                    title: Strings.networkGateway
                    text: root.draft[root.family].gateway
                    Layout.fillWidth: true
                    onEdited: value => root.changeIp("gateway", value)
                }
                ToggleRow {
                    objectName: "networkAutoDns"
                    visible: ["auto", "dhcp", "manual"].indexOf(root.draft[root.family].method) >= 0
                    title: Strings.networkAutoDns
                    checked: root.draft[root.family].autoDns
                    Layout.fillWidth: true
                    onToggled: value => root.changeIp("autoDns", value)
                }
                NetworkField {
                    objectName: "networkDns"
                    visible: ["auto", "dhcp", "manual"].indexOf(root.draft[root.family].method) >= 0
                    title: Strings.networkDns
                    hint: Strings.networkDnsHint
                    text: root.draft[root.family].dns
                    Layout.fillWidth: true
                    onEdited: value => root.changeIp("dns", value)
                }
            }
        }
    }
    ColumnLayout {
        id: controls
        visible: !root.confirmingForget
        Layout.fillWidth: true
        spacing: Metrics.space8
        Text {
            text: Strings.networkNextConnection
            color: Theme.subtext0
            font.family: Metrics.fontFamily
            font.pixelSize: Metrics.fontSmall
            wrapMode: Text.Wrap
            Layout.fillWidth: true
        }
        ActionButton {
            objectName: "networkSave"
            text: root.busy ? Strings.networkSaving : Strings.networkSave
            accent: true
            borderless: true
            enabled: root.dirty && !root.busy && root.draft.name.trim().length > 0
            Layout.fillWidth: true
            onClicked: NetworkService.saveProfile(root.draft)
        }
        ActionButton {
            objectName: "networkForget"
            text: root.initial.type === "802-11-wireless" ? Strings.networkForget : Strings.networkRemoveVpn
            glyph: Icons.trash
            destructive: true
            borderless: true
            enabled: !root.busy
            Layout.fillWidth: true
            onClicked: { root.confirmingForget = true; Qt.callLater(() => cancelForget.forceActiveFocus()); }
        }
    }
    ColumnLayout {
        visible: root.confirmingForget
        Layout.fillWidth: true
        spacing: Metrics.space8
        Text {
            text: Strings.networkForgetHint.arg(root.initial.name)
            textFormat: Text.PlainText
            color: Theme.text
            font.family: Metrics.fontFamily
            font.pixelSize: Metrics.fontBody
            wrapMode: Text.Wrap
            Layout.fillWidth: true
        }
        ActionButton {
            id: cancelForget
            objectName: "networkCancelForget"
            text: Strings.cancel
            borderless: true
            Layout.fillWidth: true
            enabled: !root.busy
            onClicked: root.confirmingForget = false
        }
        ActionButton {
            objectName: "networkConfirmForget"
            text: root.busy ? Strings.networkForgetting : root.initial.type === "802-11-wireless" ? Strings.networkForget : Strings.networkRemoveVpn
            destructive: true
            borderless: true
            enabled: !root.busy
            Layout.fillWidth: true
            onClicked: NetworkService.forgetProfile()
        }
    }
}
