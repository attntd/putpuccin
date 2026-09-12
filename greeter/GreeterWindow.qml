import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.components
import qs.core

PanelWindow {
    id: window
    anchors { top: true; bottom: true; left: true; right: true }
    color: Theme.base
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "quickshell-greeter"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    SessionAuthView {
        id: view
        anchors.fill: parent
        auth: GreeterService
        inputEnabled: GreeterService.available && !GreeterService.usersOpen
        secretInput: !GreeterService.echoResponse
        userSelectionEnabled: true
        fingerprintRetryEnabled: GreeterService.available && !GreeterService.busy
        avatarSource: GreeterService.avatarSource
        wallpaperSource: GreeterConfig.wallpaperSource
        onUserSelectionRequested: GreeterService.openUsers()
        onFingerprintRetryRequested: GreeterService.retryFingerprint()
    }
    Loader {
        anchors.fill: parent
        active: GreeterService.usersOpen
        sourceComponent: FocusScope {
            id: picker
            focus: true
            Keys.onEscapePressed: GreeterService.usersOpen = false
            Rectangle { anchors.fill: parent; color: Theme.withAlpha(Theme.base, 0.55) }
            MouseArea {
                anchors.fill: parent
                onClicked: GreeterService.usersOpen = false
            }
            Rectangle {
                anchors.centerIn: parent
                width: Math.min(Metrics.lockFieldWidth, parent.width - Metrics.space24 * 2)
                height: Math.min(parent.height - Metrics.space24 * 2,
                    users.contentHeight + Metrics.controlHeight + 2 * Metrics.space12)
                radius: Metrics.popupRadius
                color: Theme.withAlpha(Theme.base, Settings.surfaceOpacity)
                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: Metrics.space12
                    spacing: Metrics.space12
                    Text {
                        text: Strings.greeterSelectUser
                        textFormat: Text.PlainText
                        color: Theme.text
                        font.family: Metrics.fontFamily
                        font.pixelSize: Metrics.fontBody
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                    }
                    ListView {
                        id: users
                        objectName: "greeterUsers"
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        model: GreeterConfig.users
                        clip: true
                        focus: true
                        currentIndex: Math.max(0, GreeterConfig.users.findIndex(user =>
                            GreeterService.selectedUser && user.username === GreeterService.selectedUser.username))
                        keyNavigationEnabled: true
                        Keys.onReturnPressed: GreeterService.chooseUser(model[currentIndex])
                        Keys.onEnterPressed: GreeterService.chooseUser(model[currentIndex])
                        Keys.onSpacePressed: GreeterService.chooseUser(model[currentIndex])
                        delegate: ItemDelegate {
                            required property var modelData
                            required property int index
                            width: ListView.view.width
                            height: Metrics.lockFieldHeight
                            highlighted: ListView.isCurrentItem
                            text: modelData.displayName || modelData.username
                            Accessible.name: text + " (" + modelData.username + ")"
                            onClicked: GreeterService.chooseUser(modelData)
                            contentItem: Text {
                                text: parent.text
                                textFormat: Text.PlainText
                                color: Theme.text
                                font.family: Metrics.fontFamily
                                font.pixelSize: Metrics.fontBody
                                verticalAlignment: Text.AlignVCenter
                                elide: Text.ElideRight
                            }
                            background: Rectangle {
                                radius: Metrics.popupRadius
                                color: Theme.controlBackground(Theme.accent, parent.hovered, parent.down, parent.highlighted)
                            }
                        }
                        ScrollBar.vertical: ScrollBar {}
                    }
                }
            }
            Component.onCompleted: forceActiveFocus()
        }
    }
}
