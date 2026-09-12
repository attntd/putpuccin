pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.core
import qs.services

Item {
    id: root
    property var barWindow
    property var shellScreen
    readonly property string expansionSurface: ""
    readonly property int expansionWidth: 0
    readonly property Component expansionComponent: null
    readonly property var workspaceIds: HyprlandService.visibleWorkspaceIds(shellScreen)
    implicitWidth: row.implicitWidth
    implicitHeight: Metrics.controlHeight

    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: Metrics.space2

        Repeater {
            model: root.workspaceIds

            Rectangle {
                id: workspaceButton
                required property int modelData
                readonly property int workspaceId: modelData
                readonly property var workspace: HyprlandService.workspaceFor(workspaceId, root.shellScreen)
                readonly property bool active: workspace && workspace.active
                readonly property bool occupied: workspace && workspace.toplevels && workspace.toplevels.values.length > 0
                readonly property bool urgent: workspace && workspace.urgent

                implicitWidth: active ? 24 : 16
                implicitHeight: Metrics.controlHeight
                radius: 9
                color: "transparent"

                Rectangle {
                    anchors.centerIn: parent
                    width: workspaceButton.active ? 16 : workspaceButton.occupied ? 7 : 4
                    height: workspaceButton.active ? 7 : 4
                    radius: height / 2
                    color: workspaceButton.urgent ? Theme.red
                        : workspaceButton.active ? Theme.accent
                        : workspaceButton.occupied ? Theme.subtext0 : Theme.surface2

                    Behavior on width {
                        NumberAnimation { duration: Settings.reducedMotion ? 0 : Motion.fast }
                    }
                }

                MouseArea {
                    id: hover
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton
                    cursorShape: Qt.PointingHandCursor
                    onClicked: HyprlandService.activateWorkspace(workspaceButton.workspaceId, root.shellScreen)
                }
            }
        }
    }
}
