import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.core
import qs.services
import qs.modules.lockscreen
ShellRoot {
    function find(item, name) {
        if (item.objectName === name) return item;
        for (const child of item.children || []) {
            const found = find(child, name);
            if (found) return found;
        }
        return null;
    }
    readonly property var wallpaper: WallpaperService
    LockScreen {}
    Variants {
        model: Quickshell.screens
        PanelWindow {
            required property var modelData
            screen: modelData
            anchors { top: true; bottom: true; left: true; right: true }
            WlrLayershell.layer: WlrLayer.Background
            WlrLayershell.namespace: "lock-test-desktop"
            color: "#204070"
            Text { anchors.centerIn: parent; text: "TEST DESKTOP"; color: "white"; font.pixelSize: 50 }
        }
    }
    Connections {
        target: LockService
        function onReleasingChanged() { console.log("EVENT " + Date.now() + " releasing " + LockService.releasing + " wallpaper " + LockService.wallpaperSource); }
        function onLockedChanged() { console.log("EVENT " + Date.now() + " locked " + LockService.locked); }
        function onFadingOutChanged() { console.log("EVENT " + Date.now() + " fadingOut " + LockService.fadingOut); }
    }
    IpcHandler {
        target: "review"
        function reload(): void { Quickshell.reload(false); }
        function submit(): void { LockService.submit("test-only"); }
        function fingerprint(): void { LockService.reviewFingerprint(); }
        function reducedMotion(value: bool): void { Settings.reducedMotion = value; }
        function hold(value: bool): void { LockService.reviewHold(value); }
        function proceed(): void { LockService.reviewContinue(); }
        function layout(): string {
            return JSON.stringify(LockService.reviewViews.filter(view => !!view).map(view => {
                const avatar = find(view, "lockAvatar");
                const frame = find(view, "lockPasswordFrame");
                const field = find(view, "lockPassword");
                const fingerprint = find(view, "lockFingerprint");
                const error = find(view, "lockError");
                const errorVisible = error.visible;
                field.text = "test-only".repeat(50);
                field.cursorPosition = field.length;
                const result = {screenHeight: view.height,
                    groupCenter: (avatar.y + frame.y + frame.height) / 2,
                    frameWidth: frame.width, frameHeight: frame.height,
                    placeholderEmpty: field.placeholderText === "",
                    errorVisible: errorVisible, errorFits: error.contentHeight <= error.height,
                    clipped: field.clip, masked: field.displayText.indexOf("test-only") < 0,
                    // Qt creates a cursor delegate lazily, once the field has
                    // been focused; an inactive output may never need one.
                    cursorHidden: !!field.cursorDelegate && (!field.activeFocus || !!find(field, "hiddenPasswordCursor")),
                    inputEnabled: field.enabled, focused: field.activeFocus,
                    cursorInside: field.cursorRectangle.x + field.cursorRectangle.width <= field.width + 1,
                    fingerprintVisible: fingerprint.visible,
                    fingerprintInside: fingerprint.x >= 0 && fingerprint.x + fingerprint.width <= frame.width,
                    inputGap: fingerprint.x - field.x - field.width};
                field.clear();
                return result;
            }));
        }
        function state(): string { return JSON.stringify({locked:LockService.locked,secure:LockService.secure,
            currentWallpaper:WallpaperService.currentSource,wallpaper:LockService.wallpaperSource,busy:LockService.busy, message:LockService.message,fp:LockService.fingerprintState,
            releasing:LockService.releasing,fadingOut:LockService.fadingOut,watchFiles:Quickshell.watchFiles}); }
    }
}
