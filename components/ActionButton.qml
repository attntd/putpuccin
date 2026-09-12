import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.core

Button {
    id: root

    property string glyph: ""
    property real glyphScale: 1
    property real glyphWidth: -1
    property bool glyphSlashed: false
    property bool accent: false
    property bool destructive: false
    property bool borderless: false

    implicitWidth: text.length === 0 ? 42
        : contentItem.implicitWidth + leftPadding + rightPadding
    implicitHeight: 38
    leftPadding: text.length === 0 ? 0 : Metrics.space12
    rightPadding: text.length === 0 ? 0 : Metrics.space12

    component GlyphSlash: Rectangle {
        // Preserve the base symbol's position when its state changes.
        visible: root.glyphSlashed
        anchors.centerIn: parent
        width: parent.font.pixelSize * 1.2
        height: 2 * Metrics.borderWidth
        radius: height / 2
        rotation: 45
        antialiasing: true
        color: parent.color
    }

    contentItem: Item {
        implicitWidth: root.text.length > 0 ? labeledContent.implicitWidth : Metrics.iconMedium
        implicitHeight: Math.max(Metrics.iconMedium, labeledContent.implicitHeight)

        Text {
            visible: root.text.length === 0 && root.glyph.length > 0
            anchors.centerIn: parent
            text: root.glyph
            color: root.destructive ? Theme.red : root.accent ? Theme.accent : Theme.text
            font.family: Metrics.fontFamily
            font.pixelSize: Metrics.iconMedium * root.glyphScale
            GlyphSlash {}
        }

        RowLayout {
            id: labeledContent
            visible: root.text.length > 0
            anchors.fill: parent
            spacing: Metrics.space8

            Text {
                visible: root.glyph.length > 0
                text: root.glyph
                color: root.destructive ? Theme.red : root.accent ? Theme.accent : Theme.text
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.iconMedium
                horizontalAlignment: Text.AlignHCenter
                Layout.preferredWidth: root.glyphWidth >= 0 ? root.glyphWidth : implicitWidth
                Layout.minimumWidth: Layout.preferredWidth
                Layout.maximumWidth: Layout.preferredWidth
                Layout.alignment: Qt.AlignVCenter
                GlyphSlash {}
            }

            Text {
                text: root.text
                color: root.destructive ? Theme.red : root.accent ? Theme.accent : Theme.text
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.fontBody
                font.weight: Font.DemiBold
                font.underline: root.borderless && root.visualFocus
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                Layout.fillWidth: true
            }
        }
    }

    background: Rectangle {
        radius: 10
        border.width: root.borderless ? 0 : Metrics.borderWidth
        border.color: root.activeFocus ? Theme.accent
            : root.destructive ? Theme.withAlpha(Theme.red, 0.7)
            : root.accent ? Theme.accent : Theme.surface1
        color: Theme.controlBackground(root.destructive ? Theme.red
            : root.accent ? Theme.accent : Theme.text,
            root.hovered || (root.borderless && root.visualFocus), root.down, root.accent)
        opacity: root.enabled ? 1 : 0.42
    }
}
