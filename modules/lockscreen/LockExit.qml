import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Wayland
import qs.services

PanelWindow {
    id: window
    required property var shellScreen
    screen: shellScreen
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    WlrLayershell.namespace: "quickshell-de:lock-exit"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    mask: Region {}

    Image {
        id: frame
        anchors.fill: parent
        source: LockService.exitFrames[window.shellScreen.name]?.url ?? ""
        asynchronous: false
        cache: false
        // Fade the composite as one texture, preserving the exact appearance
        // of overlapping wallpaper, tint, controls and authentication feedback.
        opacity: 1
        NumberAnimation on opacity {
            id: fade
            running: LockService.fadingOut
            from: 1
            to: 0
            duration: LockService.fadeDuration
            easing.type: Easing.InOutSine
            onFinished: frame.Window.window.update()
        }
    }
    Connections {
        target: frame.Window.window
        function onFrameSwapped() {
            if (LockService.fadingOut && !fade.running && frame.opacity === 0)
                LockService.exitFadeFinished(window.shellScreen.name);
            else if (frame.status === Image.Ready)
                LockService.exitFrameReady(window.shellScreen.name);
        }
    }
    Connections {
        target: LockService
        function onLockedChanged() {
            // Keep the exact lock image opaque until a post-unlock frame.
            if (!LockService.locked) frame.Window.window.update();
        }
    }
}
