pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.core
import qs.popups
import qs.services

PanelWindow {
    id: root

    readonly property string screenName: HyprlandService.screenName(screen)
    readonly property bool requested: SurfaceManager.detachedLauncherVisible
        && SurfaceManager.detachedLauncherScreenName === screenName
    readonly property int launcherWidth: Math.min(560, Math.max(320, width - Metrics.space16 * 2))
    readonly property int collapsedLauncherHeight: launcherLoader.item
        ? launcherLoader.item.collapsedHeight : Metrics.controlHeight + Metrics.popupPadding * 2
    readonly property bool geometryReady: width >= 320
        && height >= Metrics.controlHeight + Metrics.popupPadding * 2

    visible: requested
    // This full-screen tint also enables the compositor's existing layer blur.
    color: Theme.launcherBackdrop
    exclusionMode: ExclusionMode.Ignore
    anchors {
        top: true
        right: true
        bottom: true
        left: true
    }
    WlrLayershell.namespace: "quickshell-de:detached-launcher"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: requested
        ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    MouseArea {
        anchors.fill: parent
        onClicked: SurfaceManager.closeDetachedLauncher()
    }

    Item {
        id: launcherContainer
        width: root.launcherWidth
        height: root.requested && launcherLoader.item ? launcherLoader.item.implicitHeight : 0
        anchors.horizontalCenter: parent.horizontalCenter
        y: Math.max(Metrics.space16,
            Math.round(root.height * (1 - Settings.launcherPositionFromBottom)
                - root.collapsedLauncherHeight / 2))
        clip: true
        visible: root.geometryReady

        Behavior on height {
            NumberAnimation {
                duration: Settings.reducedMotion ? 0 : Motion.standard
                easing.type: Easing.OutCubic
            }
        }

        MouseArea {
            anchors.fill: parent
        }

        Loader {
            id: launcherLoader
            anchors.fill: parent
            active: root.requested && root.geometryReady
            focus: root.requested

            sourceComponent: LauncherPopup {
                screenName: root.screenName
            }

            onLoaded: Qt.callLater(() => {
                if (item)
                    item.focusSearch();
            })
        }
    }

    Shortcut {
        sequence: "Escape"
        enabled: root.requested
        onActivated: SurfaceManager.closeDetachedLauncher()
    }
}
