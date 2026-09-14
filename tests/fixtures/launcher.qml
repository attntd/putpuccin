//@ pragma ShellId launcher-test
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io
import qs.components
import qs.core
import qs.services

ShellRoot {
    id: root
    property var frames: []
    property bool recording: false
    property var launchers: []
    Variants {
        model: Quickshell.screens
        DetachedLauncher {
            id: launcher
            required property var modelData
            screen: modelData
            Component.onCompleted: root.launchers = root.launchers.concat([launcher])
            Component.onDestruction: root.launchers = root.launchers.filter(item => item !== launcher)
            Connections {
                target: launcher.contentItem.Window.window
                function onFrameSwapped() { if (root.recording) root.frames.push(Date.now()); }
            }
        }
    }
    Window {
        id: application
        title: "Spotlight test application"
        visible: true
        width: 200
        height: 100
        Item { id: input; focus: true }
    }
    function descendants(item) {
        let result = [];
        for (const child of item.children || []) result = result.concat([child], descendants(child));
        return result;
    }
    function popup() {
        for (const window of root.launchers) {
            const result = descendants(window.contentItem).find(item => typeof item.focusSearch === "function");
            if (result) return result;
        }
        return null;
    }
    IpcHandler {
        target: "launchertest"
        function toggle(): void {
            if (SurfaceManager.detachedLauncherVisible) SurfaceManager.closeDetachedLauncher();
            else open(0);
        }
        function open(index: int): void {
            SurfaceManager.detachedLauncherScreenName = Quickshell.screens[index].name;
            SurfaceManager.detachedLauncherVisible = true;
        }
        function close(): void { SurfaceManager.closeDetachedLauncher(); }
        function focusApplication(): void { application.requestActivate(); input.forceActiveFocus(); }
        function state(): string {
            const panel = root.popup();
            if (!panel) return JSON.stringify({ open: false, applicationActive: application.active });
            const items = descendants(panel);
            const field = items.find(item => typeof item.selectAll === "function" && item.text !== undefined);
            const list = items.find(item => item.objectName === "launcherResults");
            const window = panel.Window.window;
            const origin = panel.mapToItem(window.contentItem, 0, 0);
            const current = list && list.itemAtIndex(panel.selectedResultIndex);
            const position = current ? current.mapToItem(list, 0, 0) : null;
            return JSON.stringify({ open: true, text: field.text, count: panel.resultCount,
                selected: panel.selectedResultIndex, mode: panel.mode || "", chip: panel.chipMode || "",
                navigating: panel.navigating || false, focus: field.activeFocus,
                results: (panel.results || []).slice(0, 10).map(row => ({kind: row.kind, id: row.id, title: row.title})),
                screen: panel.screenName, y: origin.y, height: panel.height, screenHeight: window.height,
                bottom: origin.y + panel.height, listHeight: list ? list.height : 0,
                listIndex: list ? list.currentIndex : -1, listY: list ? list.contentY : 0,
                selectedTop: position ? position.y : null,
                selectedVisible: position ? position.y >= -1 && position.y + current.height <= list.height + 1 : false,
                filePending: panel.fileSearchPending, fileError: panel.fileError || "",
                applicationActive: application.active });
        }
        function reduced(value: bool): void { Settings.reducedMotion = value; }
        function position(value: real): void { Settings.launcherPositionFromBottom = value; }
        function beginFrames(): void { root.frames = []; root.recording = true; }
        function endFrames(): string { root.recording = false; return JSON.stringify(root.frames); }
        function screenshot(path: string): void {
            root.popup().grabToImage(result => result.saveToFile(path));
        }
    }
}
