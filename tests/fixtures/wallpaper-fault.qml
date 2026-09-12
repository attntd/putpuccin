//@ pragma ShellId wallpaper-fault-test
import QtQuick
import QtQuick.Window
import QtTest
import Quickshell
import Quickshell.Io
import qs.core
import qs.modules.wallpaper

ShellRoot {
    Window {
        visible: true
        width: 640
        height: 400
        WallpaperView {
            id: view
            width: 320
            height: 200
            property int failures: 0
            source: Quickshell.env("QS_WALLPAPER_FAULT_A")
            onLoadFailed: failures++
        }
        TestCase { id: test; when: false }
    }
    IpcHandler {
        target: "wallpaperfault"
        function state(): string {
            return JSON.stringify({transitioning: view.transitioning,
                hasFront: !!view.front, hasIncoming: !!view.incoming,
                displayedSource: view.displayedSource,
                frontStatus: view.front ? view.front.status : -1,
                frontOpacity: view.front ? view.front.opacity : -1,
                failures: view.failures});
        }
        function begin(): string {
            test.tryVerify(() => !!view.front, 2000);
            Settings.wallpaperTransitionDuration = 1000;
            view.source = Quickshell.env("QS_WALLPAPER_FAULT_B");
            test.tryCompare(view, "transitioning", true, 2000);
            return state();
        }
        function resize(): string {
            // Changing sourceSize asks Qt to decode the now missing file again.
            view.width = 640;
            test.wait(1250);
            return state();
        }
        function recover(): string {
            Settings.wallpaperTransitionDuration = 120;
            view.source = Quickshell.env("QS_WALLPAPER_FAULT_C");
            test.tryCompare(view, "displayedSource", String(view.source), 2000);
            test.tryCompare(view, "transitioning", false, 2000);
            // A late completion with no pending image must also be harmless.
            view.finish();
            return state();
        }
    }
}
