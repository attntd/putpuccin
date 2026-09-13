pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.core
import qs.components

ColumnLayout {
    id: root
    required property NotificationReplyState replyState
    property string placeholder: ""
    signal sendRequested()
    signal cancelRequested()
    spacing: Metrics.space8

    function focusInput() { input.forceActiveFocus(Qt.MouseFocusReason); }
    Component.onCompleted: Qt.callLater(focusInput)

    TextField {
        id: input
        objectName: "notificationReplyInput"
        Layout.fillWidth: true
        implicitHeight: Metrics.popupRowHeight
        text: root.replyState.text
        onTextEdited: { root.replyState.text = text; root.replyState.error = ""; }
        maximumLength: 32768
        placeholderText: root.placeholder || Strings.notificationsReplyPlaceholder
        Accessible.name: Strings.notificationsReplyPlaceholder
        color: Theme.text
        placeholderTextColor: Theme.overlay1
        selectionColor: Theme.accent
        selectedTextColor: Theme.crust
        font.family: Metrics.fontFamily
        font.pixelSize: Metrics.fontBody
        padding: Metrics.space8
        selectByMouse: true
        background: Rectangle {
            radius: Metrics.space8
            color: Theme.controlBackground(Theme.surface0)
            border.width: Metrics.borderWidth
            border.color: input.activeFocus ? Theme.accent : Theme.surface1
        }
        onAccepted: if (!inputMethodComposing && root.replyState.text.trim()) root.sendRequested()
    }
    Text {
        Layout.fillWidth: true
        visible: root.replyState.error.length > 0
        text: root.replyState.error
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        font.family: Metrics.fontFamily
        font.pixelSize: Metrics.fontSmall
        color: Theme.warning
    }
    RowLayout {
        Layout.fillWidth: true
        spacing: Metrics.space8
        Item { Layout.fillWidth: true }
        ActionButton {
            objectName: "notificationReplySend"
            text: Strings.notificationsReplySend
            enabled: root.replyState.text.trim().length > 0
            opacity: enabled ? 1 : 0.42
            accent: true
            borderless: true
            onClicked: root.sendRequested()
        }
        ActionButton {
            objectName: "notificationReplyCancel"
            text: Strings.cancel
            borderless: true
            onClicked: root.cancelRequested()
        }
    }
}
