//@ pragma ShellId wallpaper-test
import QtQuick
import QtQuick.Window
import QtTest
import Quickshell
import Quickshell.Io
import qs.core
import qs.services
import qs.modules.wallpaper

ShellRoot {
    IpcHandler {
        target: "wallpapertest"
        function run(): string {
            const results = [];
            for (const name of ["test_order", "test_crossfade", "test_rapidChanges", "test_badImage", "test_reducedMotion", "test_disable", "test_empty"]) {
                try { tests[name](); results.push({name: name, passed: true}); }
                catch (e) { results.push({name: name, passed: false, error: String(e)}); }
            }
            return JSON.stringify(results);
        }
        function startTimer(): string {
            Settings.wallpaperIntervalMinutes = 1;
            return WallpaperService.currentSource;
        }
        function cycles(): void {
            Settings.wallpaperTransitionDuration = 20;
            for (let i = 0; i < 20; i++) {
                view.source = WallpaperService.wallpapers[i % 2];
                tests.wait(80);
            }
        }
    }
    Window {
        visible: true
        width: 640
        height: 400
        WallpaperView { id: view; anchors.fill: parent }
        TestCase {
            id: tests
            when: false
            function verify(value) { if (!value) throw new Error("Verification failed"); }
            function compare(actual, expected) {
                if (actual !== expected) throw new Error("Expected " + expected + ", received " + actual);
            }
            function test_order() {
                tryCompare(WallpaperService, "loading", false);
                tryVerify(() => WallpaperService.wallpapers.length === 4);
                compare(Settings.wallpaperIntervalMinutes, 30);
                compare(Settings.wallpaperTransitionDuration, 3000);
                verify(WallpaperService.rotating);
                const files = WallpaperService.wallpapers;
                compare(decodeURIComponent(files[0]).split("/").pop(), "a #one.PNG");
                compare(WallpaperService.currentSource, files[0]);
                for (let i = 1; i <= 4; i++) {
                    WallpaperService.next();
                    compare(WallpaperService.currentSource, files[i % 4]);
                }
            }
            function test_crossfade() {
                Settings.wallpaperTransitionDuration = 300;
                view.source = WallpaperService.wallpapers[0];
                tryCompare(view, "displayedSource", String(view.source));
                const old = view.front;
                view.source = WallpaperService.wallpapers[1];
                tryCompare(view, "transitioning", true);
                verify(old.opacity === 1);
                wait(100);
                verify(view.incoming.opacity > 0 && view.incoming.opacity < 1);
                verify(old.opacity === 1);
                tryCompare(view, "transitioning", false);
                compare(view.displayedSource, String(view.source));
                compare(String(old.source), "");
                compare(view.incoming, null);
            }
            function test_rapidChanges() {
                view.source = WallpaperService.wallpapers[0];
                tryCompare(view, "transitioning", true);
                view.source = WallpaperService.wallpapers[2];
                tryCompare(view, "displayedSource", String(view.source));
                tryCompare(view, "transitioning", false);
            }
            function test_badImage() {
                const old = view.displayedSource;
                const failed = WallpaperService.wallpapers[3];
                view.source = failed;
                wait(100);
                compare(view.displayedSource, old);
                verify(!view.transitioning);
                WallpaperService.reject(failed);
                for (let i = 0; i < 5; i++) {
                    WallpaperService.next();
                    verify(WallpaperService.currentSource !== failed);
                }
            }
            function test_reducedMotion() {
                Settings.reducedMotion = true;
                Settings.wallpaperTransitionDuration = 3000;
                view.source = WallpaperService.wallpapers[0];
                wait(250);
                compare(view.displayedSource, String(view.source));
                verify(!view.transitioning);
                Settings.reducedMotion = false;
            }
            function test_disable() {
                Settings.wallpaperEnabled = false;
                verify(!WallpaperService.rotating);
                const current = WallpaperService.currentSource;
                WallpaperService.next();
                compare(WallpaperService.currentSource, current);
                Settings.wallpaperEnabled = true;
                verify(WallpaperService.rotating);
            }
            function test_empty() {
                const directory = WallpaperService.directory;
                Settings.wallpaperDirectory = directory + "/empty";
                tryVerify(() => WallpaperService.wallpapers.length === 0);
                compare(WallpaperService.currentSource, "");
                verify(!WallpaperService.rotating);
                view.source = "";
                wait(50);
                compare(view.displayedSource, "");
                Settings.wallpaperDirectory = directory;
                tryVerify(() => WallpaperService.wallpapers.length === 4);
            }
        }
    }
}
