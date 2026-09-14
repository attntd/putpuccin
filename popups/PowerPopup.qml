pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.components
import qs.core
import qs.services

PopupFrame {
    id: root
    required property string screenName
    keyboardNavigationEnabled: true
    property string confirmation: ""
    property Item confirmationControl: null

    function cancelConfirmation() {
        root.confirmation = "";
        if (confirmationControl) confirmationControl.forceActiveFocus(Qt.BacktabFocusReason);
    }
    Keys.onShortcutOverride: event => {
        if (event.key === Qt.Key_Escape && confirmation) event.accepted = true;
    }
    Keys.onEscapePressed: {
        if (confirmation) cancelConfirmation();
        else SurfaceManager.closeOn(screenName);
    }

    function request(actionId) {
        if (SystemActions.busy || !SystemActions.available(actionId))
            return;
        if (["logout", "reboot", "poweroff"].indexOf(actionId) >= 0)
            root.confirmation = actionId;
        else {
            root.confirmation = "";
            SystemActions.execute(actionId);
        }
    }

    function confirm(actionId) {
        if (root.confirmation !== actionId || SystemActions.busy || !SystemActions.available(actionId))
            return;
        root.confirmation = "";
        SystemActions.execute(actionId);
    }

    component ConfirmableAction: ColumnLayout {
        id: actionRow
        required property string actionId
        property alias text: actionButton.text
        property alias glyph: actionButton.glyph
        property alias destructive: actionButton.destructive
        spacing: 0
        enabled: SystemActions.available(actionId) && !SystemActions.busy
        Layout.fillWidth: true

        ActionButton {
            id: actionButton
            borderless: true
            Layout.fillWidth: true
            onClicked: {
                root.confirmationControl = actionButton;
                root.request(actionRow.actionId);
            }
        }

        RevealSection {
            revealed: root.confirmation === actionRow.actionId
            externalProgress: Settings.reducedMotion ? (revealed ? 1 : 0) : -1
            topInset: Metrics.space8
            Layout.fillWidth: true

            RowLayout {
                width: parent.width
                spacing: Metrics.space8

                ActionButton {
                    text: Strings.cancel
                    borderless: true
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    onClicked: root.cancelConfirmation()
                }
                ActionButton {
                    text: Strings.confirm
                    destructive: true
                    borderless: true
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    onClicked: root.confirm(actionRow.actionId)
                }
            }
        }
    }

    Connections {
        target: SystemActions
        function onSucceeded(actionId) {
            SurfaceManager.closeOn(root.screenName);
        }
    }

    Connections {
        target: SurfaceManager
        function onChanged(screenName, surfaceId) {
            if ((!screenName || screenName === root.screenName) && surfaceId !== "power")
                root.confirmation = "";
        }
    }

    ColumnLayout {
        width: parent.width
        spacing: Metrics.space12

        Text {
            visible: SystemActions.busy
            text: Strings.loading
            color: Theme.subtext0
            font.family: Metrics.fontFamily
            font.pixelSize: Metrics.fontSmall
            horizontalAlignment: Text.AlignHCenter
            Layout.fillWidth: true
        }

        ColumnLayout {
            spacing: Metrics.space8
            Layout.fillWidth: true

            ActionButton {
                text: Strings.lock; glyph: Icons.lock
                borderless: true
                enabled: SystemActions.available("lock") && !SystemActions.busy
                Layout.fillWidth: true
                onClicked: root.request("lock")
            }
            ConfirmableAction {
                actionId: "logout"
                text: Strings.logout; glyph: Icons.logout
            }
            ActionButton {
                text: Strings.suspend; glyph: Icons.suspend
                borderless: true
                enabled: SystemActions.available("suspend") && !SystemActions.busy
                Layout.fillWidth: true
                onClicked: root.request("suspend")
            }
            ActionButton {
                text: Strings.hibernate; glyph: Icons.hibernate
                borderless: true
                enabled: SystemActions.available("hibernate") && !SystemActions.busy
                Layout.fillWidth: true
                onClicked: root.request("hibernate")
            }
            ConfirmableAction {
                actionId: "reboot"
                text: Strings.reboot; glyph: Icons.reboot
            }
            ConfirmableAction {
                actionId: "poweroff"
                text: Strings.poweroff; glyph: Icons.poweroff; destructive: true
            }
        }

        Text {
            visible: SystemActions.errorMessage.length > 0
            text: SystemActions.errorMessage
            color: Theme.error
            font.family: Metrics.fontFamily
            font.pixelSize: Metrics.fontSmall
            wrapMode: Text.Wrap
            Layout.fillWidth: true
        }
    }
}
