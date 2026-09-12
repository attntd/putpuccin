pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import qs.core

Flickable {
    id: root

    property alias text: label.text
    property alias font: label.font
    property alias color: label.color
    property string contextKey: ""
    property int horizontalAlignment: Qt.AlignLeft
    readonly property real naturalWidth: label.implicitWidth
    readonly property real overflowDistance: Math.max(0, naturalWidth - width)
    readonly property bool overflowing: width > 0 && overflowDistance > 0.5
    readonly property bool autoScrollAllowed: visible && enabled && overflowing && !Settings.reducedMotion
    readonly property bool scrolling: readAnimation.running
    readonly property int travelDuration: Math.max(Motion.elaborate,
        Math.ceil(overflowDistance / Motion.textScrollPixelsPerSecond * 1000))

    implicitWidth: label.implicitWidth
    implicitHeight: label.implicitHeight
    contentWidth: Math.max(width, label.implicitWidth)
    contentHeight: height
    flickableDirection: Flickable.HorizontalFlick
    boundsBehavior: Flickable.StopAtBounds
    pixelAligned: true
    interactive: overflowing
    clip: overflowing
    activeFocusOnTab: overflowing
    Accessible.role: Accessible.StaticText
    Accessible.name: text

    function restartReading() {
        readAnimation.stop();
        root.cancelFlick();
        root.contentX = 0;
        if (root.autoScrollAllowed)
            readAnimation.start();
    }

    function manualPosition(position) {
        readAnimation.stop();
        root.cancelFlick();
        root.contentX = Math.max(0, Math.min(root.overflowDistance, position));
    }

    onTextChanged: Qt.callLater(restartReading)
    onContextKeyChanged: Qt.callLater(restartReading)
    onOverflowDistanceChanged: Qt.callLater(restartReading)
    onAutoScrollAllowedChanged: restartReading()
    onMovementStarted: readAnimation.stop()
    Component.onCompleted: Qt.callLater(restartReading)

    Keys.onLeftPressed: root.manualPosition(root.contentX - Metrics.space24)
    Keys.onRightPressed: root.manualPosition(root.contentX + Metrics.space24)
    Keys.onPressed: event => {
        if (event.key === Qt.Key_Home || event.key === Qt.Key_End) {
            root.manualPosition(event.key === Qt.Key_Home ? 0 : root.overflowDistance);
            event.accepted = true;
        }
    }

    TapHandler { onTapped: root.forceActiveFocus() }
    HoverHandler { id: hover }

    Text {
        id: label
        x: !root.overflowing && root.horizontalAlignment === Qt.AlignHCenter
            ? (root.width - implicitWidth) / 2 : 0
        y: (root.height - implicitHeight) / 2
        width: implicitWidth
        textFormat: Text.PlainText
    }

    Rectangle {
        parent: root
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: Metrics.borderWidth
        color: Theme.accent
        visible: root.activeFocus
    }

    ToolTip {
        objectName: "scrollingTextTooltip"
        parent: root
        visible: root.overflowing && (hover.hovered || root.activeFocus)
        delay: Motion.textScrollPause
        contentItem: Text {
            text: root.text
            textFormat: Text.PlainText
            color: Theme.text
            font.family: Metrics.fontFamily
            font.pixelSize: Metrics.fontSmall
            width: Math.min(implicitWidth, Metrics.popupWidth)
            wrapMode: Text.Wrap
        }
        background: Rectangle {
            color: Theme.withAlpha(Theme.base, Settings.surfaceOpacity)
            radius: Metrics.space4
            border.width: Metrics.borderWidth
            border.color: Theme.surface1
        }
    }

    // The text only moves to expose content that cannot fit. No animation is
    // retained for a fitting label, an invisible panel, or reduced motion.
    SequentialAnimation {
        id: readAnimation
        loops: Animation.Infinite
        PauseAnimation { duration: Motion.textScrollPause }
        NumberAnimation {
            target: root
            property: "contentX"
            from: 0
            to: root.overflowDistance
            duration: root.travelDuration
            easing.type: Easing.Linear
        }
        PauseAnimation { duration: Motion.textScrollPause }
        NumberAnimation {
            target: root
            property: "contentX"
            from: root.overflowDistance
            to: 0
            duration: root.travelDuration
            easing.type: Easing.Linear
        }
    }
}
