pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets
import qs.core

Rectangle {
    id: root
    required property var result
    property bool selected: false
    signal activated()
    signal pointed()

    height: Metrics.launcherRowHeight
    radius: Metrics.launcherChipRadius
    color: selected ? Theme.controlBackground(Theme.accent, false, false, true)
        : Theme.controlBackground(Theme.text, pointer.containsMouse)
    Accessible.role: Accessible.ListItem
    Accessible.name: result.title + (result.subtitle ? ", " + result.subtitle : "")
    Accessible.selected: selected
    Accessible.onPressAction: activated()
    ToolTip.visible: pointer.containsMouse && (title.truncated || subtitle.truncated)
    ToolTip.text: Accessible.name
    ToolTip.delay: Motion.audioDeviceHold

    RowLayout {
        anchors.fill: parent
        anchors.margins: Metrics.space8
        spacing: Metrics.space8
        Item {
            Layout.preferredWidth: Metrics.iconLarge
            Layout.preferredHeight: Metrics.iconLarge
            IconImage {
                id: appIcon
                anchors.fill: parent
                source: root.result.kind !== "application" ? ""
                    : root.result.id === "signal" || root.result.id === "signal.desktop"
                        || root.result.icon === "signal-desktop" ? Icons.signalSource
                    : root.result.icon ? Quickshell.iconPath(root.result.icon) : ""
                implicitSize: Metrics.iconLarge
            }
            Text {
                anchors.centerIn: parent
                visible: appIcon.status !== Image.Ready
                text: root.result.kind === "application" ? Icons.launcher
                    : root.result.kind === "file" ? Icons.file
                    : root.result.kind === "command" ? Icons.terminal
                    : root.result.binary ? Icons.image : Icons.clipboard
                color: root.selected ? Theme.accent : Theme.subtext0
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.iconMedium
            }
        }
        ColumnLayout {
            spacing: 0
            Layout.fillWidth: true
            Text {
                id: title
                text: root.result.title
                textFormat: Text.PlainText
                color: Theme.text
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.fontSmall
                font.weight: Font.DemiBold
                elide: root.result.kind === "file" ? Text.ElideMiddle : Text.ElideRight
                Layout.fillWidth: true
            }
            Text {
                id: subtitle
                visible: text.length > 0
                text: root.result.kind === "command"
                    ? root.result.quiet ? Strings.launcherCommandBackground : Strings.launcherCommandForeground
                    : root.result.subtitle
                textFormat: Text.PlainText
                color: Theme.subtext0
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.fontSmall
                elide: Text.ElideMiddle
                Layout.fillWidth: true
            }
        }
        Text {
            text: root.result.kind === "application" ? Strings.launcherApplications
                : root.result.kind === "file" ? Strings.launcherFiles
                : root.result.kind === "command" ? Strings.launcherCommand : Strings.launcherClipboard
            color: Theme.subtext0
            font.family: Metrics.fontFamily
            font.pixelSize: Metrics.fontSmall
        }
    }
    MouseArea {
        id: pointer
        anchors.fill: parent
        hoverEnabled: true
        // Scrolling under a stationary pointer must not replace keyboard selection.
        onPositionChanged: if (containsMouse) root.pointed()
        onClicked: root.activated()
    }
}
