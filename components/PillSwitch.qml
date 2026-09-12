import QtQuick
import QtQuick.Controls
import qs.core

Switch {
    id: root

    implicitWidth: 46
    implicitHeight: 28
    padding: 0
    spacing: 0
    hoverEnabled: true

    indicator: Rectangle {
        x: (root.width - width) / 2
        y: (root.height - height) / 2
        width: 46
        height: 28
        radius: height / 2
        color: Theme.controlBackground(root.checked ? Theme.accent : Theme.text,
            root.hovered, root.down, root.checked)
        border.width: 1
        border.color: root.activeFocus ? Theme.text
            : root.checked ? Theme.accent : Theme.overlay0
        opacity: root.enabled ? 1 : 0.4

        Behavior on color {
            ColorAnimation { duration: Settings.reducedMotion ? 0 : Motion.fast }
        }

        Rectangle {
            width: 22
            height: 22
            x: root.checked ? parent.width - width - 3 : 3
            y: 3
            radius: width / 2
            color: Theme.controlBackground(Theme.text, false, false, true)
            border.width: Metrics.borderWidth
            border.color: Theme.text

            Behavior on x {
                NumberAnimation {
                    duration: Settings.reducedMotion ? 0 : Motion.standard
                    easing.type: Easing.OutCubic
                }
            }
        }
    }

    contentItem: Item {}
    background: Item {}
}
