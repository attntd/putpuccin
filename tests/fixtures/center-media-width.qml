//@ pragma ShellId center-media-width-test
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
        width: 1100
        height: 650
        color: Theme.base

        QtObject { id: bar; function activateLauncherSearch() {} }
        BarIsland {
            id: island
            anchors.horizontalCenter: parent.horizontalCenter
            y: 8
            moduleIds: ["launcher", "context", "media"]
            compactModuleId: "context"
            animateWidth: false
            animateExpansionWidth: true
            maximumContentWidth: 1000
            contentAlignment: Qt.AlignHCenter
            barWindow: bar
            shellScreen: ({name: "center-media-test", height: 650})
        }
        TestCase {
            id: tests
            when: false

            function loader() {
                return island.children.find(child => typeof child.sourceComponent !== "undefined");
            }
            function descendants(item) {
                let result = [];
                for (const child of item.children || []) {
                    result.push(child);
                    result = result.concat(descendants(child));
                }
                return result;
            }
            function snapshot(title) {
                Settings.reducedMotion = true;
                HyprlandService.testTitle = title;
                mouseMove(window.contentItem, 20, 600);
                SurfaceManager.openOn("media", "center-media-test");
                wait(200);
                waitForPolish(window, 500);
                const panel = loader().item;
                const all = descendants(panel);
                function field(name, expected) {
                    const item = all.find(child => child.objectName === name);
                    const text = descendants(item).find(child => child.text === expected && typeof child.textFormat !== "undefined");
                    const point = item.mapToItem(panel, 0, 0);
                    const textPoint = text.mapToItem(item, 0, 0);
                    return {x: point.x, y: point.y, width: item.width, height: item.height,
                        natural: item.naturalWidth, offset: item.contentX, overflow: item.overflowing,
                        scrolling: item.scrolling, visible: item.visible,
                        textX: textPoint.x, textWidth: text.width, format: text.textFormat,
                        textMatches: item.text === expected};
                }
                const named = all.filter(item => item.objectName.length > 0 && (item.visible || item.objectName === "mediaArtwork"));
                return {island: island.width, collapsed: island.collapsedWidth,
                    islandHeight: island.height, expansionHeight: island.expansionHeight,
                    expanded: island.expanded, panelVisible: panel.visible, panelOpacity: panel.opacity,
                    loader: loader().width, panel: panel.width, panelImplicit: panel.implicitWidth,
                    height: panel.height, capacity: island.maximumContentWidth,
                    sourceText: panel.sourceDescription,
                    title: field("mediaTitle", MediaService.title), artist: field("mediaArtist", MediaService.artist),
                    album: field("mediaAlbum", MediaService.album), source: field("mediaSource", panel.sourceDescription),
                    children: named.map(item => {
                        const point = item.mapToItem(panel, 0, 0);
                        return {type: String(item).split("(")[0], name: item.objectName,
                            x: point.x, y: point.y, width: item.width, height: item.height};
                    })};
            }
            function lifecycle() {
                const panel = loader().item;
                const title = descendants(panel).find(child => child.objectName === "mediaTitle");
                function state() { return {offset: title.contentX, scrolling: title.scrolling, overflow: title.overflowing}; }
                Settings.reducedMotion = false;
                wait(1100);
                const moving = state();
                // Source change with the very same title must restart reading.
                title.contextKey = "different-synthetic-source";
                wait(50);
                const sourceReset = state();
                wait(1000);
                const movingAgain = state();
                island.visible = false;
                wait(50);
                const hidden = state();
                wait(800);
                const hiddenLater = state();
                island.visible = true;
                wait(50);
                const shown = state();
                Settings.reducedMotion = true;
                wait(800);
                const reduced = state();
                title.forceActiveFocus();
                keyClick(Qt.Key_End);
                const manualEnd = state();
                keyClick(Qt.Key_Home);
                const manualHome = state();
                const tooltip = findChild(title, "scrollingTextTooltip");
                const tooltipMatches = tooltip && tooltip.contentItem.text === title.text && tooltip.contentItem.textFormat === Text.PlainText;
                keyClick(Qt.Key_Escape);
                wait(250);
                return {moving: moving, sourceReset: sourceReset, movingAgain: movingAgain,
                    hidden: hidden, hiddenLater: hiddenLater, shown: shown, reduced: reduced,
                    manualEnd: manualEnd, manualHome: manualHome, tooltipMatches: !!tooltipMatches,
                    escaped: !island.expanded, released: loader().item === null};
            }
            function transition() {
                Settings.reducedMotion = false;
                SurfaceManager.openOn("window", "center-media-test");
                wait(250);
                const start = island.width;
                SurfaceManager.openOn("media", "center-media-test");
                const widths = [];
                for (let frame = 0; frame < 20; frame++) {
                    wait(16);
                    widths.push(island.width);
                }
                waitForPolish(window, 500);
                return {start: start, final: island.width, widths: widths};
            }
        }
    }
    IpcHandler {
        target: "centermediawidthtest"
        function requested(): int { return island.hostForSurface("media").expansionWidth; }
        function ready(): bool { return !!island.hostForSurface("media") && MediaService.players.length > 0; }
        function snapshot(title: string): string { return JSON.stringify(tests.snapshot(title)); }
        function capacity(width: int): void { island.maximumContentWidth = width; }
        function lifecycle(): string { return JSON.stringify(tests.lifecycle()); }
        function cycle(): bool {
            Settings.reducedMotion = false;
            SurfaceManager.openOn("media", "center-media-test");
            tests.wait(210);
            const title = tests.descendants(tests.loader().item).find(child => child.objectName === "mediaTitle");
            const active = title.scrolling;
            SurfaceManager.closeOn("center-media-test");
            tests.wait(210);
            return active && tests.loader().item === null;
        }
        function transition(): string { return JSON.stringify(tests.transition()); }
        function screenshot(path: string): string {
            window.update();
            if (!tests.waitForRendering(window.contentItem, 500))
                throw new Error("Screenshot frame did not render");
            let finished = false;
            let saved = false;
            window.contentItem.grabToImage(result => {
                saved = result.saveToFile(path);
                finished = true;
            });
            for (let attempt = 0; attempt < 50 && !finished; attempt++)
                tests.wait(10);
            if (!finished || !saved)
                throw new Error("Screenshot was not saved");
            return JSON.stringify({expanded: island.expanded, height: island.height,
                panelHeight: tests.loader().item ? tests.loader().item.height : 0});
        }
    }
}
