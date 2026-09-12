import QtQuick
import qs.core

Rectangle {
    id: root

    default property alias content: contentRoot.data
    property bool embedded: false
    property bool showBorder: true
    property int padding: embedded ? Metrics.space12 : Metrics.popupPadding

    color: embedded ? "transparent" : Theme.withAlpha(Theme.base, Settings.surfaceOpacity)
    radius: Metrics.popupRadius
    border.width: embedded || !showBorder ? 0 : Metrics.borderWidth
    border.color: Theme.withAlpha(Theme.surface2, 0.9)
    focus: true
    activeFocusOnTab: true
    implicitWidth: contentRoot.implicitWidth + padding * 2
    implicitHeight: contentRoot.implicitHeight + padding * 2

    Rectangle {
        visible: !root.embedded && root.showBorder
        anchors.fill: parent
        anchors.margins: 1
        radius: root.radius - 1
        color: "transparent"
        border.width: 1
        border.color: Theme.withAlpha(Theme.text, 0.04)
    }

    Item {
        id: contentRoot
        anchors.fill: parent
        anchors.margins: root.padding
        implicitWidth: childrenRect.width
        implicitHeight: childrenRect.height
    }
}
