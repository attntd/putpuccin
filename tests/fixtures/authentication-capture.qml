import QtQuick
import Quickshell
import Quickshell.Wayland

ShellRoot {
    PanelWindow {
        id: window
        screen: Quickshell.screens.find(screen => screen.name === "AUTH-A") || null
        implicitWidth: 1
        implicitHeight: 1
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "auth-review-capture"
        WlrLayershell.layer: WlrLayer.Background
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        mask: Region {}
        property bool grabbing: false
        ScreencopyView {
            id: capture
            x: 2
            width: sourceSize.width / window.devicePixelRatio
            height: sourceSize.height / window.devicePixelRatio
            captureSource: window.screen
            live: false
            paintCursor: false
            onHasContentChanged: if (hasContent) Qt.callLater(window.save)
        }
        function save() {
            if (grabbing || !capture.hasContent || capture.sourceSize.width < 1)
                return;
            grabbing = true;
            if (!capture.grabToImage(result => {
                console.log("AUTH_SCREEN_SAVED", result.saveToFile(Quickshell.env("QS_REVIEW_IMAGE")));
                Qt.quit();
            })) Qt.quit();
        }
    }
}
