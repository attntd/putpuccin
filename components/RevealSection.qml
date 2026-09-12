pragma ComponentBehavior: Bound
import QtQuick
import qs.core

Item {
    id: root
    default property alias content: body.data
    property bool revealed: false
    property real topInset: 0
    property real externalProgress: -1
    property real progress: externalProgress >= 0 ? externalProgress : revealed ? 1 : 0
    implicitHeight: (body.childrenRect.height + topInset) * progress
    opacity: progress
    visible: progress > 0
    enabled: revealed
    clip: true

    Behavior on progress {
        enabled: root.externalProgress < 0
        NumberAnimation {
            duration: Settings.reducedMotion ? Motion.fast : Motion.standard
            easing.type: Easing.InOutCubic
        }
    }

    Item {
        id: body
        y: root.topInset
        width: parent.width
        height: childrenRect.height
    }
}
