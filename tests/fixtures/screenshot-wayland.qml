pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.core
import qs.modules.screenshot
import qs.services

ShellRoot {
    // A deterministic scene owned by this private compositor. No desktop image
    // or clipboard data from the user's production session enters this fixture.
    Variants {
        model: Quickshell.screens
        PanelWindow {
            required property var modelData
            screen: modelData
            anchors { left: true; right: true; top: true; bottom: true }
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.namespace: "quickshell-test:screenshot-background"
            WlrLayershell.layer: WlrLayer.Background
            color: modelData.name === "SCREENSHOT-A" ? "#1e5078" : "#501e6e"
            Rectangle {
                width: parent.width / 2
                height: parent.height / 3
                color: "#aa283c"
            }
            Rectangle {
                x: 80
                y: 90
                width: 50
                height: 50
                color: "#ffffff"
            }
        }
    }

    Screenshot {}

    IpcHandler {
        target: "screenshottest"
        function select(name: string, x: real, y: real, width: real, height: real): bool {
            return ScreenshotService.selectRegion(name, x, y, width, height);
        }
        function monitor(name: string): bool {
            ScreenshotService.focusScreen(name);
            return ScreenshotService.selectMonitor(name);
        }
        function perform(action: string): bool { return ScreenshotService.perform(action); }
        function directory(): string { return ScreenshotService.directory; }
        function records(): string { return JSON.stringify(ScreenshotService.screens.map(entry => { const record = Object.assign({}, entry); delete record.grab; return record; })); }
        // Test-only reference export for independent pixel comparisons.
        function reference(name: string, path: string): bool { return ScreenshotService.recordFor(name).grab.saveToFile(path); }
        function screenState(): string {
            return JSON.stringify(Array.from(Quickshell.screens).map(screen => ({
                name: screen.name, width: screen.width, height: screen.height,
                devicePixelRatio: screen.devicePixelRatio, orientation: screen.orientation
            })));
        }
        function setDirectory(path: string): void { Settings.screenshotDirectory = path; }
    }
}
