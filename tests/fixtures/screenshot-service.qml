//@ pragma ShellId screenshot-service-test
import QtQuick
import Quickshell
import Quickshell.Io
import qs.core
import qs.services

ShellRoot {
    readonly property var service: ScreenshotService
    property bool gateCapture: false
    Connections {
        target: ScreenshotService
        function onCaptureStarting(token) { if (gateCapture) ScreenshotService.holdCapture("test-panel", token); }
    }
    FloatingWindow { id: scene; visible: true; implicitWidth: 4; implicitHeight: 4 }
    Component { id: pixels; Rectangle { color: "#465078"; x: 8 } }

    IpcHandler {
        target: "screenshotservicetest"
        function snapshot(): string {
            return JSON.stringify({phase: ScreenshotService.phase, active: ScreenshotService.active,
                mode: ScreenshotService.mode, screenName: ScreenshotService.screenName,
                generation: ScreenshotService.generation, directory: ScreenshotService.directory,
                screens: ScreenshotService.screens.map(entry => { const record = Object.assign({}, entry); delete record.grab; return record; }), windows: ScreenshotService.windows,
                selection: ScreenshotService.selection, hasSelection: ScreenshotService.hasSelection,
                errorMessage: ScreenshotService.errorMessage, editorAvailable: ScreenshotService.editorAvailable,
                paintCursor: ScreenshotService.paintCursor, lastSavedPath: ScreenshotService.lastSavedPath,
                nativeScreens: Array.from(Quickshell.screens).map(screen => ({name: screen.name,
                    x: screen.x, y: screen.y, width: screen.width, height: screen.height})),
                labels: {locked: Strings.screenshotLocked, prepare: Strings.screenshotPrepareFailed,
                    crop: Strings.screenshotExportFailed, clipboard: Strings.screenshotClipboardMissing,
                    editor: Strings.screenshotEditorMissing}});
        }
        function begin(mode: string, screen: string): bool { return ScreenshotService.begin(mode, screen); }
        function cancel(): void { ScreenshotService.cancel(); }
        function captured(name: string, width: int, height: int, token: int): void {
            const item = pixels.createObject(scene.contentItem, {width: width, height: height});
            item.grabToImage(result => {
                ScreenshotService.captured(name, width, height, token, result);
                item.destroy();
            });
        }
        function gate(value: bool): void {
            gateCapture = value;
            if (!value) ScreenshotService.releaseCapture("test-panel", ScreenshotService.generation);
        }
        function metadata(kind: string, text: string, token: int): void {
            ScreenshotService.metadata(kind, text, token);
        }
        function select(name: string, x: real, y: real, width: real, height: real): bool {
            return ScreenshotService.selectRegion(name, x, y, width, height);
        }
        function invalidRegion(name: string): bool {
            return ScreenshotService.selectRegion(name, NaN, 0, 40, 40);
        }
        function setMode(mode: string): void { ScreenshotService.setMode(mode); }
        function cancelNative(value: bool): void { ScreenshotService.cancelNativeOnce = value; }
        function perform(action: string): bool { return ScreenshotService.perform(action); }
        function lock(locked: bool, releasing: bool): void {
            LockService.locked = locked;
            LockService.releasing = releasing;
        }
    }
}
