//@ pragma ShellId center-toolbar-test
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
        width: 900
        height: 550

        QtObject {
            id: bar
            function activateLauncherSearch() {}
        }

        BarIsland {
            id: island
            anchors.horizontalCenter: parent.horizontalCenter
            y: 8
            moduleIds: ["launcher", "context", "media"]
            compactModuleId: "context"
            animateWidth: false
            animateExpansionWidth: true
            contentAlignment: Qt.AlignHCenter
            barWindow: bar
            shellScreen: ({name: "center-test", height: 550})
        }

        TestCase {
            id: tests
            when: false

            function check(ok, message) {
                if (!ok)
                    throw new Error(message);
            }

            function settle(delay) {
                wait(delay);
                check(waitForPolish(window, 500), "Layout did not settle");
            }

            function panelLoader() {
                for (const child of island.children) {
                    if (typeof child.sourceComponent !== "undefined")
                        return child;
                }
                throw new Error("Expansion Loader is missing");
            }

            function descendants(item) {
                let result = [];
                for (const child of item.children || []) {
                    result.push(child);
                    result = result.concat(descendants(child));
                }
                return result;
            }

            function idle() {
                check(!island.modulesRevealed && island.moduleRevealProgress === 0,
                    "Secondary modules retained their reveal state");
                for (const id of ["launcher", "media"]) {
                    const host = island.hostForSurface(id);
                    check(host.width === 0 && host.opacity === 0 && !host.enabled,
                        id + " remains visible, interactive or takes space: " + host.width);
                }
                check(island.width === island.hostForSurface("window").width + Metrics.space8,
                    "Collapsed island keeps extra padding or icon space: " + island.width);
                check(!panelLoader().active && !panelLoader().item, "Closed panel was retained");
                fullTerminalContext();
            }

            function fullTerminalContext() {
                const host = island.hostForSurface("window");
                const context = host.loadedItem;
                check(context.windowHost === "test-host" && context.windowCommand === "fish"
                    && context.windowTitle === "/work/app", "Terminal context lost a metadata field");
                const hostLabel = descendants(context).find(item => item.text === "test-host");
                const title = descendants(context).find(item => typeof item.sourceText !== "undefined");
                check(!!hostLabel && hostLabel.visible && hostLabel.width >= hostLabel.implicitWidth,
                    "Hostname label is hidden or clipped");
                check(!!title && title.sourceText === "/work/app · fish"
                    && title.text === title.sourceText && title.width >= title.implicitWidth,
                    "Directory or process text is missing or clipped");
                check(context.width >= context.implicitWidth && host.width >= context.width,
                    "Context host clips the full terminal information");
            }

            function hover(surface) {
                const host = island.hostForSurface(surface);
                mouseMove(host, host.width / 2, host.height / 2);
            }

            function click(surface) {
                const host = island.hostForSurface(surface);
                mouseClick(host, host.width / 2, host.height / 2);
            }

            function revealed(surface) {
                check(island.expansionSurface === surface && island.expanded,
                    "Wrong panel after clicking " + surface + ": " + island.expansionSurface);
                check(island.moduleRevealProgress === 1, "Icons did not finish revealing");
                for (const id of ["launcher", "media"]) {
                    const host = island.hostForSurface(id);
                    check(host.width >= Metrics.minHitSize && host.opacity === 1 && host.enabled,
                        id + " was not revealed");
                }
                check(island.width === 430 && panelLoader().width === 422,
                    surface + " changed common panel width: " + island.width);
                const launcher = island.hostForSurface("launcher");
                const context = island.hostForSurface("window");
                const media = island.hostForSurface("media");
                check(Math.abs(context.x - launcher.x - launcher.width - Metrics.space8) < 0.01
                    && Math.abs(media.x - context.x - context.width - Metrics.space8) < 0.01,
                    "Center module gaps are not equal to 8 px");
                fullTerminalContext();
            }

            function run(reduced) {
                Settings.reducedMotion = reduced;
                mouseMove(window.contentItem, 20, 450);
                SurfaceManager.closeOn("center-test");
                settle(320);
                idle();
                const collapsedWidth = island.width;
                hover("window"); settle(240); idle();
                click("window");
                let intermediate = false;
                for (let frame = 0; frame < 15; frame++) {
                    wait(16);
                    intermediate = intermediate || (island.moduleRevealProgress > 0
                        && island.moduleRevealProgress < 1);
                    for (const id of ["launcher", "media"]) {
                        const host = island.hostForSurface(id);
                        check(host.width >= 0 && host.width <= host.implicitWidth + 0.01,
                            id + " has invalid intermediate width");
                        check(island.moduleRevealProgress === 1 || host.clip,
                            id + " can paint over the context during reveal");
                    }
                }
                settle(20);
                check(reduced || intermediate, "No animated reveal was observed");
                revealed("window");
                const move = descendants(panelLoader().item).find(item =>
                    item.text === Strings.moveToWorkspace && typeof item.leftPadding !== "undefined"
                    && typeof item.down !== "undefined");
                check(!!move && move.text === "Przenieś do workspace", "Workspace label is incorrect");
                check(move.implicitWidth <= move.width + 0.01,
                    "Workspace label exceeds its button: " + move.implicitWidth + "/" + move.width);
                const moveGeometry = {natural: move.implicitWidth, available: move.width};
                mouseMove(move, move.width / 2, move.height / 2); settle(200);
                check(!panelLoader().item.workspacePickerOpen, "Hover opened workspace picker");
                mouseClick(move); settle(100);
                check(panelLoader().item.workspacePickerOpen, "Click did not open workspace picker");
                mouseMove(window.contentItem, 20, 450); settle(200);
                check(panelLoader().item.workspacePickerOpen, "Pointer exit closed workspace picker");
                mouseClick(move); settle(100);
                check(!panelLoader().item.workspacePickerOpen, "Second click did not close workspace picker");

                for (const surface of ["launcher", "media", "window", "media"]) {
                    const previous = island.expansionSurface;
                    hover(surface); settle(220);
                    revealed(previous);
                    click(surface); settle(220);
                    revealed(surface);
                    mouseMove(island, island.width / 2, Settings.barHeight + 16);
                    settle(Settings.hoverCloseDelay + 30);
                    revealed(surface);
                }

                mouseMove(window.contentItem, 20, 450);
                settle(300);
                revealed("media");
                click("media"); settle(240);
                idle();
                // IPC/keyboard entry must reveal controls even with the cursor away.
                SurfaceManager.openOn("launcher", "center-test");
                settle(240);
                revealed("launcher");
                panelLoader().item.focusSearch();
                check(window.activeFocusItem !== null, "Launcher did not accept keyboard focus");
                keyClick(Qt.Key_Escape);
                settle(240);
                idle();
                return {collapsed: collapsedWidth, expanded: 430, reduced: reduced,
                    moveLabel: moveGeometry};
            }

            function fallback() {
                island.moduleIds = ["launcher", "media"];
                settle(240);
                check(!island.hasCompactModule && island.moduleRevealProgress === 1,
                    "Configuration without context lost its controls");
                island.moduleIds = ["launcher", "context", "media"];
                settle(240);
                const details = descendants(island.hostForSurface("window").loadedItem)
                    .find(item => typeof item.typing === "boolean");
                tryCompare(details, "typing", false, Motion.typewriterStep * 45 + Motion.standard);
                check(!details.typing, "Recreated context did not finish its title animation");
                idle();
                // Legacy hover settings cannot restore automatic expansion.
                Settings.moduleOptions = {context: {expandOnHover: true}};
                hover("window");
                settle(240);
                idle();
                click("window"); settle(240);
                click("launcher");
                settle(240);
                revealed("launcher");
                mouseMove(window.contentItem, 20, 450);
                settle(Settings.hoverCloseDelay + Motion.standard + 60);
                revealed("launcher");
                click("launcher"); settle(240);
                Settings.moduleOptions = {};
                idle();
            }
        }
    }

    IpcHandler {
        target: "centertoolbartest"
        function ready(): bool { return !!island.hostForSurface("window"); }
        function run(reduced: bool): string {
            try { return JSON.stringify({passed: true, geometry: tests.run(reduced)}); }
            catch (error) { return JSON.stringify({passed: false, error: String(error)}); }
        }
        function fallback(): string {
            try { tests.fallback(); return JSON.stringify({passed: true}); }
            catch (error) { return JSON.stringify({passed: false, error: String(error)}); }
        }
    }
}
