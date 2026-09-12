//@ pragma ShellId context-title-test
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
        width: 1000
        height: 140
        visible: true
        color: Theme.base
        QtObject { id: bar; function activateLauncherSearch() {} }
        BarIsland {
            id: island
            anchors.horizontalCenter: parent.horizontalCenter
            y: 16
            moduleIds: ["launcher", "context", "media"]
            compactModuleId: "context"
            contentAlignment: Qt.AlignHCenter
            maximumContentWidth: 980
            animateWidth: false
            barWindow: bar
            shellScreen: ({name: "context-title-test", height: 650})
        }
        TestCase {
            id: tests
            when: false
            function descendants(item) {
                let result = [];
                for (const child of item.children || []) {
                    result.push(child);
                    result = result.concat(descendants(child));
                }
                return result;
            }
            function snapshot(data) {
                Settings.reducedMotion = true;
                Settings.moduleOptions = {context: {expandOnHover: false}};
                SurfaceManager.closeOn("context-title-test");
                mouseMove(window.contentItem, 8, 120);
                HyprlandService.fixtureWindow = data.desktop ? null : {
                    address: "fixture", title: data.title,
                    lastIpcObject: {class: data.windowClass, initialClass: data.initialClass || ""}};
                HyprlandService.terminalContextByAddress = {fixture: {
                    host: data.host || "", cwd: data.cwd || "", command: data.command || ""}};
                HyprlandService.pathRevision++;
                wait(80);
                const context = island.hostForSurface("window").loadedItem;
                if (data.reveal) {
                    mouseClick(context, context.width / 2, context.height / 2);
                    wait(80);
                }
                waitForPolish(window, 500);
                const all = descendants(context);
                const image = all.find(item => item.objectName === "contextApplicationIcon");
                if (image) {
                    image.source = data.forceFallback ? "" : Qt.binding(() => context.windowIconSource);
                    wait(40);
                }
                const texts = all.filter(item => item.visible && typeof item.text === "string")
                    .map(item => {
                        const p = item.mapToItem(context, 0, 0);
                        return {text: item.text, x: p.x, y: p.y, width: item.width, height: item.height,
                            natural: item.implicitWidth, format: item.textFormat,
                            typing: typeof item.typing === "boolean" ? item.typing : false};
                    }).sort((a, b) => a.x - b.x);
                const launcher = island.hostForSurface("launcher");
                const center = island.hostForSurface("window");
                const media = island.hostForSurface("media");
                return {texts: texts, title: context.windowTitle, host: context.windowHost,
                    command: context.windowCommand, width: context.width, natural: context.implicitWidth,
                    island: island.width, expanded: island.expanded, reveal: island.modulesRevealed,
                    launcherWidth: launcher.width, mediaWidth: media.width,
                    gaps: data.reveal ? [center.x - launcher.x - launcher.width,
                        media.x - center.x - center.width] : [],
                    imageReady: !!image && image.status === Image.Ready,
                    imageWidth: image ? image.width : 0, iconToken: Metrics.iconMedium, mediaGlyph: Icons.media,
                    iconSource: image ? String(image.source) : ""};
            }
        }
    }
    IpcHandler {
        target: "contexttitletest"
        function ready(): bool { return !!island.hostForSurface("window"); }
        function snapshot(data: string): string { return JSON.stringify(tests.snapshot(JSON.parse(data))); }
        function screenshot(path: string): void {
            window.update();
            if (!tests.waitForRendering(window.contentItem, 500)) throw new Error("No rendered frame");
            let done = false;
            let saved = false;
            window.contentItem.grabToImage(result => { saved = result.saveToFile(path); done = true; });
            for (let attempt = 0; attempt < 50 && !done; attempt++) tests.wait(10);
            if (!done || !saved) throw new Error("Screenshot not saved");
        }
    }
}
