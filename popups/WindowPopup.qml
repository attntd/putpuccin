pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.components
import qs.core
import qs.services

PopupFrame {
    id: root

    required property string screenName
    required property var shellScreen
    readonly property var toplevel: HyprlandService.activeToplevelFor(shellScreen)
    readonly property var workspace: HyprlandService.activeWorkspace(shellScreen)
    readonly property int activeWorkspaceId: workspace ? workspace.id : 0
    property bool workspacePickerOpen: false

    function closeWindow() {
        if (HyprlandService.closeActiveWindow(root.shellScreen))
            SurfaceManager.closeOn(root.screenName);
    }

    function moveWindow(workspaceId) {
        if (HyprlandService.moveActiveWindowToWorkspace(workspaceId, root.shellScreen))
            SurfaceManager.closeOn(root.screenName);
    }

    ColumnLayout {
        width: parent.width
        spacing: Metrics.space12

        RowLayout {
            Layout.fillWidth: true
            spacing: Metrics.space8

            ActionButton {
                text: Strings.moveToWorkspace
                borderless: true
                enabled: root.toplevel !== null
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                Layout.preferredWidth: 1
                onClicked: root.workspacePickerOpen = !root.workspacePickerOpen
            }

            ActionButton {
                text: Strings.closeWindow
                borderless: true
                destructive: true
                enabled: root.toplevel !== null
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                Layout.preferredWidth: 1
                onClicked: root.closeWindow()
            }
        }

        RowLayout {
            visible: root.workspacePickerOpen
            Layout.fillWidth: true
            spacing: Metrics.space6

            Repeater {
                model: 10

                ActionButton {
                    required property int index
                    readonly property int workspaceId: index + 1
                    text: String(workspaceId)
                    borderless: true
                    leftPadding: Metrics.space4
                    rightPadding: Metrics.space4
                    accent: workspaceId === root.activeWorkspaceId
                    enabled: root.toplevel !== null && workspaceId !== root.activeWorkspaceId
                    Layout.fillWidth: true
                    Layout.minimumWidth: 0
                    Layout.preferredWidth: 1
                    onClicked: root.moveWindow(workspaceId)
                }
            }
        }

        EmptyState {
            visible: root.toplevel === null
            Layout.fillWidth: true
            title: Strings.noActiveWindow
        }
    }
}
