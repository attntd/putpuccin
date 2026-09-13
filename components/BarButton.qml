import QtQuick
import QtQuick.Layouts
import qs.core

Item {
    id: root

    property string icon: ""
    property string text: ""
    property string tooltip: ""
    property bool active: false
    property bool warning: false
    property bool compact: false
    property bool iconAtEnd: false
    property bool iconSlashed: false
    property color foreground: warning ? Theme.warning : Theme.text
    property color iconForeground: foreground

    signal clicked()
    signal middleClicked()
    signal rightClicked()
    signal wheel(int delta)

    implicitWidth: Math.max(Metrics.minHitSize, content.implicitWidth + Metrics.space12)
    implicitHeight: Metrics.controlHeight

    RowLayout {
        id: content
        anchors.centerIn: parent
        spacing: root.compact ? 0 : Metrics.space6
        layoutDirection: root.iconAtEnd ? Qt.RightToLeft : Qt.LeftToRight

        Text {
            visible: root.icon.length > 0
            text: root.icon
            color: root.iconForeground
            font.family: Metrics.fontFamily
            font.pixelSize: Metrics.iconMedium
            Layout.alignment: Qt.AlignVCenter

            Rectangle {
                // Keep the base glyph and its layout unchanged across states.
                visible: root.iconSlashed
                anchors.centerIn: parent
                width: parent.font.pixelSize * 1.2
                height: 2 * Metrics.borderWidth
                radius: height / 2
                rotation: 45
                antialiasing: true
                color: parent.color
            }
        }

        Text {
            visible: !root.compact && root.text.length > 0
            text: root.text
            color: root.foreground
            font.family: Metrics.fontFamily
            font.pixelSize: Metrics.fontSmall
            font.weight: Font.DemiBold
            elide: Text.ElideRight
            Layout.maximumWidth: 180
            Layout.alignment: Qt.AlignVCenter
        }

    }

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
        onClicked: mouse => {
            if (mouse.button === Qt.MiddleButton)
                root.middleClicked();
            else if (mouse.button === Qt.RightButton)
                root.rightClicked();
            else
                root.clicked();
        }
        onWheel: event => root.wheel(event.angleDelta.y)
    }
}
