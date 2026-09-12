pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.core
import qs.services

Rectangle {
    id: root
    required property var workspace
    readonly property bool selected: workspace.focused
    implicitWidth: Metrics.workspaceTileWidth
    implicitHeight: Metrics.workspaceTileHeight
    radius: Metrics.popupRadius
    color: Theme.controlBackground(selected ? Theme.accent : Theme.text,
        hover.hovered, false, selected)
    border.width: 0
    Accessible.name: Strings.workspace + " " + workspace.name

    HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: root.workspace.activate() }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Metrics.space12
        spacing: Metrics.space12
        RowLayout {
            Layout.fillWidth: true
            Rectangle {
                implicitWidth: Metrics.controlHeight
                implicitHeight: Metrics.controlHeight
                radius: Metrics.space8
                color: root.selected ? Theme.accent : Theme.controlBackground(Theme.text, true)
                Text {
                    anchors.centerIn: parent
                    text: root.workspace.id === 10 ? "0" : String(root.workspace.id)
                    color: root.selected ? Theme.base : Theme.text
                    font.family: Metrics.fontFamily
                    font.pixelSize: Metrics.fontBody
                    font.bold: true
                }
            }
            Text {
                text: Strings.workspace + " " + root.workspace.name
                color: root.selected ? Theme.accent : Theme.text
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.fontBody
                font.bold: true
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
            Text {
                text: String(root.workspace.toplevels.values.length)
                color: Theme.subtext0
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.fontSmall
            }
        }
        ListView {
            id: windows
            Layout.fillWidth: true
            Layout.fillHeight: true
            model: root.workspace.toplevels.values
            spacing: Metrics.space8
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            delegate: RowLayout {
                id: entry
                required property var modelData
                width: windows.width - Metrics.space8
                spacing: Metrics.space8
                Text {
                    text: HyprlandService.isTerminal(entry.modelData) ? Icons.terminal
                        : HyprlandService.isBrowser(entry.modelData) ? Icons.browser : Icons.window
                    color: Theme.text
                    font.family: Metrics.fontFamily
                    font.pixelSize: Metrics.iconMedium
                    Layout.alignment: Qt.AlignTop
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Metrics.space2
                    Text {
                        text: HyprlandService.toplevelClass(entry.modelData) || entry.modelData.title
                        textFormat: Text.PlainText
                        color: Theme.text
                        font.family: Metrics.fontFamily
                        font.pixelSize: Metrics.fontSmall
                        font.bold: true
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                    Text {
                        text: entry.modelData.title || ""
                        textFormat: Text.PlainText
                        color: Theme.subtext0
                        font.family: Metrics.fontFamily
                        font.pixelSize: Metrics.fontSmall
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                }
                ToolTip.visible: entryHover.hovered
                ToolTip.text: entry.modelData.title || ""
                HoverHandler { id: entryHover }
            }
        }
    }
}
