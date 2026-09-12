pragma ComponentBehavior: Bound
import QtQuick
import qs.core

Item {
    id: root
    required property string text
    property int maximumLineCount: 5
    property bool expanded: false
    property alias font: preview.font
    property alias color: preview.color
    readonly property bool truncated: preview.truncated
    property real expansion: expanded ? 1 : 0
    readonly property real expandedHeight: fullText.item ? fullText.item.implicitHeight : preview.implicitHeight
    implicitHeight: preview.implicitHeight + expansion * (expandedHeight - preview.implicitHeight)
    clip: expansion > 0 && expansion < 1

    Behavior on expansion {
        enabled: root.visible && !Settings.reducedMotion
        NumberAnimation {
            id: revealAnimation
            duration: Motion.elaborate
            easing.type: Easing.InOutCubic
        }
    }
    onVisibleChanged: if (!visible) revealAnimation.complete()

    // Measure the compact preview independently of the animated viewport.
    // Changing its height must never change wrapping or truncation feedback.
    Text {
        id: preview
        width: parent.width
        text: root.text
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        maximumLineCount: root.maximumLineCount
        elide: Text.ElideRight
        visible: root.expansion === 0
        color: Theme.text
        font.family: Metrics.fontFamily
        font.pixelSize: Metrics.fontBody
    }
    Loader {
        id: fullText
        objectName: "notificationFullText"
        width: parent.width
        active: root.expanded || root.expansion > 0
        visible: root.expansion > 0
        // Keep full text until collapse finishes, then release its layout.
        sourceComponent: Text {
            text: root.text
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            font: preview.font
            color: preview.color
        }
    }
}
