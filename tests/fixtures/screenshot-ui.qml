//@ pragma ShellId screenshot-ui-test
import QtQuick
import QtQuick.Window
import QtTest
import Quickshell
import Quickshell.Io
import qs.core
import qs.modules.screenshot
import "modules/screenshot/SelectionGeometry.js" as Geometry

ShellRoot {
    id: fixture
    readonly property string screenName: Quickshell.screens[0].name
    property int testWidth: 800

    QtObject {
        id: mockController
        property bool active: true
        property string phase: "selecting"
        property string mode: "region"
        property string screenName: fixture.screenName
        property string errorMessage: ""
        property bool editorAvailable: false
        property var screens: [{ name: fixture.screenName, x: 0, y: 0, width: 800, height: 600,
            pixelWidth: 1600, pixelHeight: 1200, url: Quickshell.env("QS_SCREENSHOT_IMAGE") }]
        property var windows: []
        property var selection: ({})
        readonly property bool hasSelection: !!selection.screenName || (selection.screenName === ""
            && selection.width > 0 && selection.height > 0)
        property var actions: []
        property var failures: []
        property int cancelCount: 0

        function presented(name) {}
        function reset() {
            active = true;
            phase = "selecting";
            mode = "region";
            screenName = fixture.screenName;
            errorMessage = "";
            editorAvailable = false;
            selection = ({});
            actions = [];
            failures = [];
            cancelCount = 0;
            windows = [
                { id: "front", title: "Synthetic front window", screenName: fixture.screenName,
                  x: 180, y: 100, width: 180, height: 140 },
                { id: "back", title: "Synthetic back window", screenName: fixture.screenName,
                  x: 100, y: 80, width: 400, height: 250 },
                { id: "other", title: "Different monitor", screenName: "other-monitor",
                  x: 0, y: 0, width: 800, height: 600 }
            ];
        }
        function setMode(value) { mode = value; selection = ({}); }
        function focusScreen(name) { screenName = name; }
        function selectRegion(name, x, y, width, height) {
            selection = { screenName: name, x: x, y: y, width: width, height: height };
            screenName = name;
        }
        function selectWindow(id) {
            const entry = windows.find(item => item.id === id);
            if (entry)
                selectRegion(entry.screenName, entry.x, entry.y, entry.width, entry.height);
        }
        function selectMonitor(name) {
            const entry = screens.find(item => item.name === name);
            if (entry)
                selectRegion(name, 0, 0, entry.width, entry.height);
        }
        function perform(action) { actions = actions.concat([action]); }
        function cancel() { cancelCount++; active = false; }
        function fail(message) { failures = failures.concat([message]); cancel(); }
    }

    LazyLoader {
        id: loader
        active: false
        component: ScreenshotOverlay {
            shellScreen: Quickshell.screens[0]
            controller: mockController
            implicitWidth: fixture.testWidth
        }
    }

    TestCase {
        id: tests
        parent: loader.item ? loader.item.contentItem : null
        when: false

        function check(condition, description) {
            if (!condition)
                throw new Error(description);
        }
        function equal(actual, expected, description) {
            check(JSON.stringify(actual) === JSON.stringify(expected), description + ": "
                + JSON.stringify(actual) + " != " + JSON.stringify(expected));
        }
        function item(name) {
            const found = findChild(loader.item.contentItem, name);
            check(!!found, "Missing object: " + name);
            return found;
        }
        function settle() {
            wait(40);
            check(waitForPolish(loader.item.contentItem, 500), "Layout did not settle");
        }
        function click(name) {
            const control = item(name);
            check(control.visible && control.enabled, "Control unavailable: " + name);
            mouseClick(control, control.width / 2, control.height / 2);
            settle();
        }
        function activateCanvas() {
            tests.Window.window.requestActivate();
            loader.item.focusCanvas();
            wait(20);
        }
        function open() {
            mockController.reset();
            loader.active = true;
            settle();
            activateCanvas();
            check(loader.item.visible, "Overlay did not become visible");
        }
        function close() {
            loader.active = false;
            wait(40);
            check(loader.item === null, "LazyLoader retained the closed overlay");
        }
        function bounds(name) {
            const control = item(name);
            const position = control.mapToItem(loader.item.contentItem, 0, 0);
            check(position.x >= 0 && position.y >= 0
                && position.x + control.width <= loader.item.width + 0.1
                && position.y + control.height <= loader.item.height + 0.1,
                name + " escapes the monitor: " + JSON.stringify(position));
        }
        function geometry() {
            equal(Geometry.fromPoints(250, 180, 100, 50, 800, 600),
                { x: 100, y: 50, width: 150, height: 130 }, "Reverse drag");
            equal(Geometry.fromPoints(-30, 700, 850, -10, 800, 600),
                { x: 0, y: 0, width: 800, height: 600 }, "Clamp drag to monitor");
            equal(Geometry.clipped({ x: -50, y: 10, width: 100, height: 900 }, 800, 600),
                { x: 0, y: 10, width: 50, height: 590 }, "Partly hidden window");
            equal(Geometry.clipped({ x: NaN, y: 0, width: 20, height: 20 }, 800, 600),
                { x: 0, y: 0, width: 0, height: 0 }, "Invalid rectangle");
            equal(Geometry.pixels({ x: 1, y: 1, width: 21, height: 19 },
                { width: 2400, height: 1500, pixelWidth: 2880, pixelHeight: 1800 }),
                { width: 26, height: 23 }, "Fractional display scale");
            equal(Geometry.adjust({ x: 790, y: 590, width: 10, height: 10 }, 3, 5, false, 800, 600),
                { x: 790, y: 590, width: 10, height: 10 }, "Move clamp");
            equal(Geometry.adjust({ x: 790, y: 590, width: 10, height: 10 }, -20, -20, true, 800, 600),
                { x: 790, y: 590, width: 1, height: 1 }, "Minimum keyboard size");
            check(Geometry.hitWindow(mockController.windows, 200, 120).id === "front", "Wrong stacking order");
            check(Geometry.hitWindow(mockController.windows.slice(0, 2), 600, 500) === null, "Empty hit test");
            for (const rect of [null, { x: 0, y: 0, width: 800, height: 600 },
                { x: 700, y: 540, width: 100, height: 60 }, { x: 0, y: 0, width: 100, height: 30 }]) {
                const position = Geometry.toolbarPosition(rect, 450, 140, 800, 600, 16);
                check(position.x >= 16 && position.y >= 16 && position.x + 450 <= 784
                    && position.y + 140 <= 584, "Toolbar geometry escapes monitor");
            }
        }
        function run() {
            open();
            geometry();
            const mouse = item("screenshotSelectionMouse");
            check(!item("screenshotActions").visible, "Actions appear before a selection");
            check(item("screenshotFrozenImage").status === Image.Ready, "Frozen image did not load");
            bounds("screenshotToolbar");

            // Actual pointer events: reverse drag, then verify service coordinates and badge.
            mousePress(mouse, 300, 200);
            mouseMove(mouse, 100, 80, 20, Qt.LeftButton);
            check(!item("screenshotToolbar").visible, "Toolbar obscures dragging");
            mouseRelease(mouse, 100, 80);
            settle();
            equal(mockController.selection, { screenName: fixture.screenName, x: 100, y: 80, width: 200, height: 120 },
                "Mouse selection");
            equal(loader.item.previewPixels, { width: 400, height: 240 }, "Pixel dimensions");
            check(item("screenshotActions").visible, "Selection actions missing");
            bounds("screenshotToolbar");
            check(!item("screenshotEdit").enabled, "Missing editor remains enabled");
            item("screenshotEdit").clicked();
            keyClick(Qt.Key_E);
            equal(mockController.actions, [], "Unavailable edit activated");
            click("screenshotCopy");
            click("screenshotSave");
            mockController.editorAvailable = true;
            click("screenshotEdit");
            equal(mockController.actions, ["copy", "save", "edit"], "Action dispatch");

            mockController.actions = [];
            activateCanvas();
            keyClick(Qt.Key_Right);
            keyClick(Qt.Key_Down, Qt.ShiftModifier);
            check(mockController.selection.x === 101 && mockController.selection.height === 121,
                "Keyboard move/resize failed");
            keyClick(Qt.Key_Return);
            keyClick(Qt.Key_C, Qt.ControlModifier);
            keyClick(Qt.Key_S, Qt.ControlModifier);
            keyClick(Qt.Key_E);
            equal(mockController.actions, ["copy", "copy", "save", "edit"], "Keyboard actions");

            // Buttons remain reachable using native tab navigation and Space activation.
            mockController.actions = [];
            item("screenshotModeRegion").forceActiveFocus(Qt.TabFocusReason);
            keyClick(Qt.Key_Tab);
            check(item("screenshotModeWindow").activeFocus, "Tab did not reach window mode");
            keyClick(Qt.Key_Space);
            check(mockController.mode === "window", "Keyboard mode activation failed");
            activateCanvas();
            keyClick(Qt.Key_Right);
            check(mockController.selection.x === 180, "First keyboard window selection failed");
            keyClick(Qt.Key_Right);
            check(mockController.selection.x === 100, "Keyboard window cycle failed");
            mouseClick(mouse, 200, 120);
            settle();
            check(mockController.selection.x === 180 && mockController.selection.width === 180,
                "Mouse did not select the frontmost window");

            mockController.actions = [];
            mouseMove(mouse, 130, 110);
            settle();
            check(item("screenshotWindowHover").visible, "Unselected window hover lacks a candidate outline");
            check(mockController.selection.x === 180, "Hover silently changed screenshot target");
            keyClick(Qt.Key_Return);
            equal(mockController.actions, ["copy"], "Enter after hover failed");
            check(mockController.selection.x === 180, "Enter used the uncommitted hover target");
            mouseClick(mouse, 130, 110);
            settle();
            check(mockController.selection.x === 100 && !item("screenshotWindowHover").visible,
                "Window click failed to commit the hovered target");

            mockController.windows = [];
            keyClick(Qt.Key_2);
            settle();
            check(item("screenshotHint").text === Strings.screenshotNoWindows, "Missing empty window state");
            keyClick(Qt.Key_Right);
            check(!mockController.hasSelection, "Empty window mode selected something");

            keyClick(Qt.Key_3);
            settle();
            check(mockController.mode === "monitor" && mockController.selection.width === 800,
                "Keyboard monitor mode selection failed");
            bounds("screenshotToolbar");
            bounds("screenshotDimensions");

            const originalScreens = mockController.screens;
            mockController.screens = originalScreens.concat([{ name: "other-monitor", x: 800, y: 0,
                width: 1200, height: 800, pixelWidth: 1440, pixelHeight: 960,
                url: Quickshell.env("QS_SCREENSHOT_IMAGE") }]);
            keyClick(Qt.Key_Right);
            check(mockController.screenName === "other-monitor"
                && mockController.selection.width === 1200
                && !loader.item.ownsFocus, "Keyboard did not hand focus to another monitor");
            mockController.screens = originalScreens;
            mockController.focusScreen(fixture.screenName);
            activateCanvas();
            keyClick(Qt.Key_1);
            keyClick(Qt.Key_Left);
            check(mockController.selection.width > 0, "Keyboard region did not create initial selection");

            // Busy commands must be guarded even if a stale click handler runs.
            mockController.actions = [];
            mockController.phase = "working";
            settle();
            check(!item("screenshotCopy").enabled && !item("screenshotModeRegion").enabled,
                "Busy controls stayed enabled");
            item("screenshotCopy").clicked();
            keyClick(Qt.Key_Return);
            keyClick(Qt.Key_3);
            equal(mockController.actions, [], "Busy action escaped guard");
            check(mockController.mode === "region", "Busy mode changed");

            mockController.phase = "error";
            mockController.errorMessage = "Synthetic retryable error";
            settle();
            check(item("screenshotError").visible && item("screenshotCopy").enabled,
                "Retryable error state lost controls");

            // A selection made on another monitor does not expose local actions.
            mockController.selectRegion("other-monitor", 0, 0, 100, 100);
            settle();
            check(!loader.item.selectedHere && !item("screenshotActions").visible,
                "Foreign monitor selection leaked local actions");
            mockController.focusScreen(fixture.screenName);
            activateCanvas();
            keyClick(Qt.Key_Escape);
            check(mockController.cancelCount === 1 && !loader.item.visible, "Escape did not cancel");
            close();

            // Compact screens keep all modes/actions inside the same monitor.
            fixture.testWidth = 320;
            open();
            check(item("screenshotCanvas").width === 320, "Compact fixture has the wrong size");
            mockController.selectRegion(fixture.screenName, 20, 20, 260, 200);
            settle();
            for (const name of ["screenshotToolbar", "screenshotModeRegion", "screenshotModeWindow",
                "screenshotModeMonitor", "screenshotCancel", "screenshotCopy", "screenshotSave", "screenshotEdit"])
                bounds(name);
            item("screenshotCanvas").grabToImage(result => result.saveToFile(Quickshell.env("QS_SCREENSHOT_PROOF") + "/compact.png"));
            wait(100);
            close();
            fixture.testWidth = 800;

            // Display-server closure, graphics resource loss, and unreadable
            // snapshots all terminate the session instead of trapping input.
            open();
            loader.item.closed();
            check(!mockController.active && mockController.failures.length === 1,
                "Display-server close left capture active");
            close();
            open();
            loader.item.resourcesLost();
            check(!mockController.active && mockController.failures.length === 1,
                "Graphics resource loss left capture active");
            close();
            open();
            const screensBeforeError = mockController.screens;
            const broken = Object.assign({}, screensBeforeError[0],
                { url: "file:///tmp/screenshot-missing-fixture.png" });
            mockController.screens = [broken];
            settle();
            check(!mockController.active && mockController.failures.length === 1,
                "Unreadable snapshot left capture active");
            close();
            mockController.screens = screensBeforeError;
            return { passed: true, width: 800, height: 600 };
        }
        function cycle() {
            open();
            keyClick(Qt.Key_3);
            settle();
            check(mockController.hasSelection && loader.item.selectedHere, "Reopened selection failed");
            keyClick(Qt.Key_Escape);
            check(mockController.cancelCount === 1, "Reopened cancellation failed");
            close();
            return { passed: true };
        }
        function proof() {
            open();
            mockController.selectRegion(fixture.screenName, 100, 80, 420, 250);
            settle();
            item("screenshotCanvas").grabToImage(result => result.saveToFile(Quickshell.env("QS_SCREENSHOT_PROOF") + "/region.png"));
            wait(100);
            keyClick(Qt.Key_2);
            keyClick(Qt.Key_Right);
            settle();
            item("screenshotCanvas").grabToImage(result => result.saveToFile(Quickshell.env("QS_SCREENSHOT_PROOF") + "/window.png"));
            wait(100);
            keyClick(Qt.Key_3);
            settle();
            item("screenshotCanvas").grabToImage(result => result.saveToFile(Quickshell.env("QS_SCREENSHOT_PROOF") + "/monitor.png"));
            wait(100);
            close();
            return true;
        }
    }

    IpcHandler {
        target: "screenshottest"
        function ready(): bool { return true; }
        function run(): string {
            try { return JSON.stringify(tests.run()); }
            catch (error) { return JSON.stringify({ passed: false, error: String(error) }); }
        }
        function cycle(): string {
            try { return JSON.stringify(tests.cycle()); }
            catch (error) { return JSON.stringify({ passed: false, error: String(error) }); }
        }
        function proof(): bool { return tests.proof(); }
    }
}
