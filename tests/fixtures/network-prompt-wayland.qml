import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.core
import qs.services
import qs.audit
import qs.modules.statusbar

ShellRoot {
    PanelWindow {
        id: window
        anchors { top: true; right: true; bottom: true; left: true }
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "network-prompt-test"
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
        mask: Region { item: island }
        BarIsland {
            id: island
            x: window.width - width - 12
            y: 8
            moduleIds: ["network"]
            barWindow: window
            shellScreen: window.screen
            minimumExpansionWidth: Metrics.popupWidth
            contentAlignment: Qt.AlignRight
        }
    }
    function find(item, name) {
        if (!item) return null;
        if (item.objectName === name) return item;
        for (const child of item.children || []) {
            const found = find(child, name);
            if (found) return found;
        }
        return null;
    }
    function point(item) {
        if (!item) return null;
        const p = item.mapToItem(window.contentItem, item.width / 2, item.height / 2);
        return [Math.round(p.x), Math.round(p.y)];
    }
    Component.onCompleted: {
        Networking.network.connected = false;
        Networking.network.known = false;
    }
    IpcHandler {
        target: "networkPrompt"
        function ready(): bool { return !!island.hostForSurface("network"); }
        function open(): void { SurfaceManager.openOn("network", "test-a"); }
        function close(): void { SurfaceManager.closeOn("test-a"); }
        function state(): string {
            const list = find(island, "networkNearbyList");
            const input = find(island, "networkPassword");
            const button = find(island, "networkConnect");
            return JSON.stringify({open: island.expanded, retained: island.expanded,
                input: !!input && input.visible, empty: !input || input.text.length === 0,
                inputHeight: input ? input.height : 0, buttonHeight: button ? button.height : 0,
                muted: !!input && input.background.border.color.toString() === Theme.surface1.toString(),
                buttonBorder: button ? button.background.border.width : -1,
                row: list ? point(list.itemAtIndex(0)) : null, field: point(input),
                scanning: Networking.wifi.scannerEnabled, wifiEnabled: Networking.wifiEnabled,
                popupUsers: NetworkService.popupUsers, connections: Networking.pskConnections});
        }
        function capture(path: string): void { island.grabToImage(result => result.saveToFile(path)); }
        function reduced(): void { Settings.reducedMotion = true; }
    }
}
