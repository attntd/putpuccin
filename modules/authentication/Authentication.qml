import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.core
import qs.services

Scope {
    id: root
    readonly property var service: AuthenticationService
    readonly property var targetScreen: Quickshell.screens.find(screen => screen.name === service.screenName) || Quickshell.screens[0] || null
    readonly property bool retained: service.active

    LazyLoader {
        active: root.retained && root.targetScreen !== null
        Variants {
            model: root.targetScreen ? [root.targetScreen] : []
            PanelWindow {
                id: window
                required property var modelData
                property bool layoutReady: false
                screen: modelData
                visible: layoutReady && root.service.active
                // Use the launcher's full-screen tint and compositor blur.
                color: Theme.authenticationBackdrop
                implicitWidth: screen ? screen.width : 1
                implicitHeight: screen ? screen.height : 1
                anchors {
                    top: true
                    right: true
                    bottom: true
                    left: true
                }
                exclusionMode: ExclusionMode.Ignore
                WlrLayershell.namespace: "quickshell-de:authentication"
                WlrLayershell.layer: WlrLayer.Overlay
                WlrLayershell.keyboardFocus: root.service.interactive ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
                mask: Region {
                    item: root.service.interactive ? backdrop : null
                }
                Item {
                    id: backdrop
                    anchors.fill: parent
                }
                AuthenticationView {
                    id: view
                    anchors.centerIn: parent
                    width: Math.min(Metrics.authWidth, Math.max(0, window.implicitWidth - 2 * Metrics.space16))
                    height: Math.min(implicitHeight, Math.max(0, window.implicitHeight - 2 * Metrics.space16))
                    auth: root.service
                }
                // Hyprland fades the completed layer, including its blur. Keep
                // its QML pixels stable from the first mapped buffer to unmap.
                Component.onCompleted: Qt.callLater(() => {
                    view.prepareLayout();
                    window.layoutReady = true;
                })
            }
        }
    }
}
