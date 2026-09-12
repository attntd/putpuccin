pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.components
import qs.core

ColumnLayout {
    id: root
    required property var service
    readonly property string prompt: service.pairingPrompt
    readonly property bool needsInput: prompt === "pin" || prompt === "passkey"
    readonly property bool needsConfirmation: needsInput || ["confirmation", "authorization", "service"].indexOf(prompt) >= 0
    spacing: Metrics.space8

    function resetInput() {
        codeInput.clear();
        if (needsInput) codeInput.forceActiveFocus(Qt.OtherFocusReason);
        else if (needsConfirmation) confirmButton.forceActiveFocus(Qt.OtherFocusReason);
        else cancelButton.forceActiveFocus(Qt.OtherFocusReason);
    }
    function submit() {
        if (confirmButton.enabled) service.respond(service.pairingRequestId, codeInput.text);
    }
    Component.onCompleted: Qt.callLater(resetInput)
    Connections {
        target: root.service
        function onPairingRequestIdChanged() { Qt.callLater(root.resetInput); }
    }

    Text {
        text: root.service.pairingName
        textFormat: Text.PlainText
        color: Theme.text
        font.family: Metrics.fontFamily
        font.pixelSize: Metrics.fontBody
        font.weight: Font.DemiBold
        wrapMode: Text.Wrap
        Layout.fillWidth: true
    }
    Text {
        text: root.prompt === "confirmation" ? Strings.bluetoothConfirmHint
            : root.prompt === "pin" ? Strings.bluetoothPinHint
            : root.prompt === "passkey" ? Strings.bluetoothPasskeyHint
            : root.prompt === "displayPin" || root.prompt === "displayPasskey" ? Strings.bluetoothDisplayHint
            : root.prompt === "authorization" || root.prompt === "service" ? Strings.bluetoothAuthorizeHint
            : root.service.pairingPhase === "connecting" ? Strings.connecting : Strings.bluetoothPairing
        color: Theme.subtext0
        font.family: Metrics.fontFamily
        font.pixelSize: Metrics.fontSmall
        wrapMode: Text.Wrap
        Layout.fillWidth: true
    }
    Text {
        objectName: "bluetoothPairingCode"
        visible: root.service.pairingCode.length > 0
        text: root.service.pairingCode
        textFormat: Text.PlainText
        color: Theme.accent
        font.family: Metrics.fontFamily
        font.pixelSize: Metrics.iconLarge
        font.letterSpacing: 3
        horizontalAlignment: Text.AlignHCenter
        Layout.fillWidth: true
    }
    Text {
        visible: root.prompt === "displayPasskey"
        text: Strings.bluetoothEntered.arg(root.service.pairingEntered)
        color: Theme.subtext0
        font.family: Metrics.fontFamily
        font.pixelSize: Metrics.fontSmall
        Layout.alignment: Qt.AlignHCenter
    }
    TextField {
        id: codeInput
        objectName: "bluetoothPinInput"
        visible: root.needsInput
        Layout.fillWidth: true
        implicitHeight: Metrics.popupRowHeight
        maximumLength: root.prompt === "pin" ? 16 : 6
        validator: RegularExpressionValidator {
            regularExpression: root.prompt === "passkey" ? /^[0-9]{1,6}$/ : /^.{1,16}$/
        }
        placeholderText: root.prompt === "pin" ? Strings.bluetoothPin : Strings.bluetoothPasskey
        Accessible.name: placeholderText
        color: Theme.text
        placeholderTextColor: Theme.overlay1
        selectionColor: Theme.accent
        selectedTextColor: Theme.crust
        font.family: Metrics.fontFamily
        font.pixelSize: Metrics.fontBody
        selectByMouse: true
        inputMethodHints: Qt.ImhNoPredictiveText | Qt.ImhSensitiveData
            | (root.prompt === "passkey" ? Qt.ImhDigitsOnly : Qt.ImhNone)
        background: Rectangle {
            radius: 10
            color: Theme.controlBackground(Theme.surface0)
            border.width: codeInput.activeFocus ? Metrics.borderWidth : 0
            border.color: Theme.accent
        }
        onAccepted: root.submit()
    }
    RowLayout {
        Layout.fillWidth: true
        spacing: Metrics.space8
        ActionButton {
            id: cancelButton
            objectName: "bluetoothCancelPairing"
            text: Strings.cancel
            borderless: true
            Layout.fillWidth: true
            onClicked: root.service.cancelPairing()
        }
        ActionButton {
            id: confirmButton
            objectName: "bluetoothConfirmPairing"
            visible: root.needsConfirmation
            enabled: visible && (!root.needsInput || codeInput.acceptableInput)
            text: root.prompt === "confirmation" ? Strings.bluetoothCodesMatch : Strings.bluetoothPair
            accent: true
            borderless: true
            Layout.fillWidth: true
            onClicked: root.submit()
        }
    }
}
