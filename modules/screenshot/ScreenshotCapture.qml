pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.core

PanelWindow {
    id: root
    required property var shellScreen
    required property var controller
    property int token: -1
    readonly property var record: controller.recordFor(shellScreen.name)
    property bool grabbing: false

    function captureFailed() {
        if (token === controller.generation && controller.phase === "capturing")
            controller.fail(Strings.screenshotCaptureFailed);
    }

    Component.onCompleted: {
        token = controller.generation;
        if (capture.hasContent) Qt.callLater(captureFrame);
    }

    screen: shellScreen
    implicitWidth: 1
    implicitHeight: 1
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "quickshell-de:screenshot-capture"
    WlrLayershell.layer: WlrLayer.Background
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    mask: Region {}

    // The capture item is outside the 1 px backing window and cannot appear in
    // the screenshot. A mapped window is still required by Qt's grabToImage.
    ScreencopyView {
        id: capture
        x: 2
        width: sourceSize.width / root.devicePixelRatio
        height: sourceSize.height / root.devicePixelRatio
        captureSource: root.shellScreen
        live: false
        paintCursor: root.controller.paintCursor
        onHasContentChanged: if (hasContent) Qt.callLater(root.captureFrame)
        onStopped: if (!hasContent) root.captureFailed()
    }
    function captureFrame() {
        if (grabbing || !record || controller.generation !== token || controller.phase !== "capturing"
                || !capture.hasContent || capture.sourceSize.width < 1 || capture.sourceSize.height < 1) return;
        grabbing = true;
        const pixels = capture.sourceSize;
        const captureToken = token;
        const name = shellScreen.name;
        const service = controller;
        // grabToImage schedules its own scenegraph synchronization and readback.
        // Its callback, rather than a delay, confirms that the pixels are ready.
        const started = capture.grabToImage(result => {
            if (!service || service.generation !== captureToken || service.phase !== "capturing") return;
            service.captured(name, pixels.width, pixels.height, captureToken, result);
        });
        if (!started) service.fail(Strings.screenshotCaptureFailed);
    }
    onResourcesLost: root.captureFailed()
}
