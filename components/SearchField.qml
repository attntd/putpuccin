import QtQuick
import QtQuick.Controls
import qs.core

TextField {
    id: root
    signal searchFocusRequested()

    placeholderText: Strings.search
    color: Theme.text
    placeholderTextColor: Theme.overlay1
    selectionColor: Theme.accent
    selectedTextColor: Theme.crust
    font.family: Metrics.fontFamily
    font.pixelSize: Metrics.fontBody
    leftPadding: 38
    selectByMouse: true

    background: Rectangle {
        radius: 10
        color: Theme.controlBackground(Theme.surface0)
        border.width: 0
    }

    Text {
        anchors.left: parent.left
        anchors.leftMargin: Metrics.space12
        anchors.verticalCenter: parent.verticalCenter
        text: Icons.search
        color: Theme.subtext0
        font.family: Metrics.fontFamily
        font.pixelSize: Metrics.iconSmall
    }

    HoverHandler {
        cursorShape: Qt.IBeamCursor
    }
    TapHandler {
        onTapped: {
            root.searchFocusRequested();
            root.forceActiveFocus(Qt.MouseFocusReason);
        }
    }
}
