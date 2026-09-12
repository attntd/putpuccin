//@ pragma ShellId toolbar-width-test
import QtQuick
import QtQuick.Window
import QtTest
import Quickshell
import Quickshell.Io
import qs.core
import qs.services
import qs.modules.statusbar

ShellRoot {
    Window {
        id: window
        visible: true
        width: 800
        height: 1000

        QtObject {
            id: bar
            function activateClipboardSearch() {}
            function activateNotificationSearch() {}
        }

        QtObject {
            id: testScreen
            readonly property string name: "width-test"
            readonly property real width: window.width
            readonly property real height: window.height
        }

        BarIsland {
            id: island
            x: window.width - width
            moduleIds: ["tray", "clock"]
            minimumExpansionWidth: Metrics.popupWidth
            barWindow: bar
            shellScreen: testScreen
            contentAlignment: Qt.AlignRight
        }

        TestCase {
            id: tests
            when: false

            function check(ok, message) {
                if (!ok)
                    throw new Error(message);
            }

            function panelLoader() {
                for (const child of island.children) {
                    if (typeof child.sourceComponent !== "undefined")
                        return child;
                }
                throw new Error("Expansion Loader is missing");
            }

            function checkPanel(surface) {
                const loader = panelLoader();
                check(island.expanded && island.expansionSurface === surface,
                    "Wrong expansion for " + surface);
                const expected = Metrics.popupWidth;
                check(island.width === expected,
                    surface + " frame width: " + island.width);
                check(loader.item && loader.width === expected - Metrics.space8,
                    surface + " Loader width: " + loader.width);
                check(loader.item.width === loader.width,
                    surface + " content width: " + loader.item.width);
                check(loader.item.height > 0, surface + " has no content height");
                check(waitForPolish(window, 500), surface + " layout did not settle");
                return {surface: surface, frame: island.width, content: loader.item.width};
            }

            function run() {
                Settings.reducedMotion = true;
                Settings.trayVisibleItems = 0;
                const widths = [];
                for (const moduleId of ["clipboard", "tray", "audio", "brightness",
                    "network", "bluetooth", "battery", "notifications", "quickSettings"]) {
                    SurfaceManager.closeOn("width-test");
                    island.moduleIds = [moduleId, "clock"];
                    wait(40);
                    check(island.collapsedWidth < Metrics.popupWidth,
                        moduleId + " collapsed width would hide the regression");
                    const surface = moduleId;
                    check(!!island.hostForSurface(surface), moduleId + " host is unavailable");
                    SurfaceManager.openOn(surface, "width-test");
                    wait(40);
                    widths.push(checkPanel(surface));
                    SurfaceManager.openOn("calendar", "width-test");
                    wait(40);
                    checkPanel("calendar");
                    SurfaceManager.openOn(surface, "width-test");
                    wait(40);
                    checkPanel(surface);
                    SurfaceManager.closeOn("width-test");
                    wait(40);
                    check(!panelLoader().active && !panelLoader().item,
                        moduleId + " retained its closed panel");
                    check(island.width === island.collapsedWidth,
                        moduleId + " did not restore its collapsed width");
                }

                island.moduleIds = ["bluetooth", "clock"];
                wait(40);
                SurfaceManager.openOn("bluetooth", "width-test"); wait(40);
                window.width = 600; wait(40);
                checkPanel("bluetooth");
                SurfaceManager.closeOn("width-test"); wait(40);
                window.width = 800;

                // Inspect every animation step during the historical 360→410
                // brightness/calendar handoff, not just the final dimensions.
                island.moduleIds = ["brightness", "clock"];
                wait(40);
                Settings.reducedMotion = false;
                SurfaceManager.openOn("brightness", "width-test");
                wait(250);
                for (const surface of ["calendar", "brightness", "calendar"]) {
                    SurfaceManager.openOn(surface, "width-test");
                    for (let frame = 0; frame < 15; frame++) {
                        wait(16);
                        checkPanel(surface);
                    }
                }
                SurfaceManager.closeOn("width-test");
                wait(250);
                return widths;
            }
        }
    }

    IpcHandler {
        target: "widthtest"
        function ready(): bool {
            Settings.trayVisibleItems = 0;
            return !!island.hostForSurface("tray");
        }
        function run(): string {
            try {
                return JSON.stringify({passed: true, widths: tests.run()});
            } catch (error) {
                return JSON.stringify({passed: false, error: String(error)});
            }
        }
    }
}
