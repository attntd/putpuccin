import QtQuick
import QtQuick.Controls
import qs.core

Slider {
    id: root

    implicitHeight: 26
    live: true

    background: Rectangle {
        x: root.leftPadding
        y: root.topPadding + root.availableHeight / 2 - height / 2
        implicitWidth: 200
        implicitHeight: 6
        width: root.availableWidth
        height: implicitHeight
        radius: 3
        color: Theme.controlBackground(Theme.text, true)

        Rectangle {
            width: root.visualPosition * parent.width
            height: parent.height
            radius: parent.radius
            color: Theme.controlBackground(Theme.accent, false, false, true)
            border.width: 0
        }
    }

    handle: Rectangle {
        x: root.leftPadding + root.visualPosition * (root.availableWidth - width)
        y: root.topPadding + root.availableHeight / 2 - height / 2
        implicitWidth: 16
        implicitHeight: 16
        radius: 8
        color: Theme.withAlpha(root.pressed ? Theme.lavender : Theme.accent, 0.65)
        border.width: 0
    }
}
