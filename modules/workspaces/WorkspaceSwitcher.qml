pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.components
import qs.core

LazyLoader {
    id: root
    required property var shellScreen
    required property string screenName
    active: SurfaceManager.workspaceSwitcherVisible
        && SurfaceManager.workspaceSwitcherScreenName === screenName

    component: PanelWindow {
        id: window
        screen: root.shellScreen
        readonly property var occupiedWorkspaces: Hyprland.workspaces.values
            .filter(workspace => workspace.id > 0 && workspace.toplevels.values.length > 0)
            .sort((a, b) => a.id - b.id)
        readonly property real availableWidth: Math.max(200, root.shellScreen.width - Metrics.space24 * 2)
        readonly property real availableHeight: Math.max(200, root.shellScreen.height - Metrics.space24 * 2)
        readonly property int columns: Math.max(1, Math.min(3, occupiedWorkspaces.length,
            Math.floor((availableWidth - Metrics.space24) / (Metrics.workspaceTileWidth + Metrics.space12))))
        readonly property int rows: Math.max(1, Math.ceil(occupiedWorkspaces.length / columns))
        readonly property real tileHeight: Math.min(Metrics.workspaceTileHeight,
            Math.max(140, (availableHeight - Metrics.space24 * 2 - header.implicitHeight
                - rows * Metrics.space12) / rows))
        implicitWidth: Math.min(availableWidth,
            columns * Metrics.workspaceTileWidth + (columns - 1) * Metrics.space12 + Metrics.space24 * 2)
        implicitHeight: Math.min(availableHeight, content.implicitHeight + Metrics.space24 * 2)
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "quickshell-de:workspace-switcher"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        Rectangle {
            anchors.fill: parent
            radius: Metrics.popupRadius
            color: Theme.withAlpha(Theme.base, Settings.surfaceOpacity)
            ColumnLayout {
                id: content
                anchors.fill: parent
                anchors.margins: Metrics.space24
                spacing: Metrics.space16
                RowLayout {
                    id: header
                    Layout.fillWidth: true
                    Text {
                        text: Strings.workspace + " " + (Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.name : "")
                        color: Theme.text
                        font.family: Metrics.fontFamily
                        font.pixelSize: Metrics.fontTitle
                        font.bold: true
                        Layout.fillWidth: true
                    }
                    Text {
                        text: Strings.workspaceSwitcherHint
                        color: Theme.subtext0
                        font.family: Metrics.fontFamily
                        font.pixelSize: Metrics.fontSmall
                    }
                }
                ScrollView {
                    id: workspaceScroll
                    visible: window.occupiedWorkspaces.length > 0
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.preferredHeight: Math.min(grid.implicitHeight,
                        window.availableHeight - header.implicitHeight - Metrics.space24 * 2 - Metrics.space16)
                    contentWidth: availableWidth
                    clip: true
                    ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                    GridLayout {
                        id: grid
                        width: workspaceScroll.availableWidth
                        columns: window.columns
                        columnSpacing: Metrics.space12
                        rowSpacing: Metrics.space12
                        Repeater {
                            model: window.occupiedWorkspaces
                            WorkspaceTile {
                                required property var modelData
                                workspace: modelData
                                Layout.fillWidth: true
                                Layout.preferredWidth: Metrics.workspaceTileWidth
                                Layout.preferredHeight: window.tileHeight
                            }
                        }
                    }
                }
                EmptyState {
                    visible: window.occupiedWorkspaces.length === 0
                    Layout.fillWidth: true
                    icon: Icons.monitor
                    title: Strings.noOccupiedWorkspaces
                }
            }
        }
    }
}
