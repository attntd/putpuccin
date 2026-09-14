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
    readonly property real preferredLauncherHeight: launcherLoader.item
        ? launcherLoader.item.preferredHeight : collapsedLauncherHeight
    readonly property bool geometryReady: width >= 320
        && height >= Metrics.controlHeight + Metrics.popupPadding * 2
    onRequestedChanged: if (!requested) heightAnimation.stop()

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
        y: Math.max(Metrics.launcherScreenMargin,
            Math.min(root.height - root.preferredLauncherHeight - Metrics.launcherScreenMargin,
                Math.max(Metrics.space16, Math.round(root.height * (1 - Settings.launcherPositionFromBottom)
                    - root.collapsedLauncherHeight / 2))))
        clip: true
        visible: root.geometryReady

        Behavior on height {
            enabled: root.requested && !Settings.reducedMotion
            NumberAnimation {
                id: heightAnimation
                duration: Motion.standard
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
                maximumHeight: Math.max(0, root.height - launcherContainer.y - Metrics.launcherScreenMargin)
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
        onActivated: {
            if (launcherLoader.item) launcherLoader.item.handleKey({ key: Qt.Key_Escape });
            else SurfaceManager.closeDetachedLauncher();
        }
    }
}
