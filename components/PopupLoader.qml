pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.core

Item {
    id: root

    required property string surfaceId
    required property string screenName
    required property var anchorItem
    property Component contentComponent
    property int popupWidth: 360
    property int popupHeight: 360
    property int horizontalGravity: Edges.Right
    property bool requested: SurfaceManager.isOpen(surfaceId, screenName)
    property bool retained: requested

    function close() {
        SurfaceManager.closeOn(root.screenName);
    }

    onRequestedChanged: {
        if (requested) {
            closeDelay.stop();
            retained = true;
        } else if (retained) {
            closeDelay.restart();
        }
    }

    Timer {
        id: closeDelay
        interval: Settings.reducedMotion ? 1 : Motion.fast
        onTriggered: root.retained = false
    }

    LazyLoader {
        active: root.retained

        PopupWindow {
            id: popup

            visible: root.retained
            implicitWidth: root.popupWidth
            implicitHeight: root.popupHeight
            color: "transparent"
            grabFocus: true

            onVisibleChanged: {
                if (!visible && root.requested)
                    root.close();
            }

            anchor.item: root.anchorItem
            anchor.edges: Edges.Bottom | root.horizontalGravity
            anchor.gravity: Edges.Bottom | root.horizontalGravity
            anchor.margins.top: Metrics.barGap
            anchor.adjustment: PopupAdjustment.SlideX | PopupAdjustment.FlipY
                | PopupAdjustment.ResizeX | PopupAdjustment.ResizeY

            Loader {
                id: contentLoader
                anchors.fill: parent
                sourceComponent: root.contentComponent
                focus: root.requested
                opacity: root.requested ? 1 : 0
                transform: Translate {
                    y: root.requested ? 0 : -Metrics.space8
                    Behavior on y {
                        NumberAnimation {
                            duration: Settings.reducedMotion ? 0 : Motion.fast
                            easing.type: Easing.OutCubic
                        }
                    }
                }

                Behavior on opacity {
                    NumberAnimation { duration: Settings.reducedMotion ? 0 : Motion.fast }
                }

                onLoaded: (item as Item).forceActiveFocus()
            }

            Shortcut {
                sequence: "Escape"
                enabled: root.requested
                onActivated: root.close()
            }
        }
    }
}
