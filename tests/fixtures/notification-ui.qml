//@ pragma ShellId quickshell-notifications-ui-test
pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.services
import qs.core
import qs.modules.statusbar
import qs.modules.notifications
ShellRoot {
    id: root
    readonly property var service: NotificationService
    StatusBar { id: bar; screen: Quickshell.screens[0] }
    Variants {
        id: toastWindows
        model: Quickshell.screens
        NotificationToasts { required property var modelData; screen: modelData }
    }
    function tree(item) {
        return {type: String(item), name: item.objectName, x:item.x, y:item.y, width:item.width, height:item.height,
            visible:item.visible, focus:item.activeFocus, text:item.text === undefined ? "" : item.text,
            children:(item.children || []).map(root.tree)};
    }
    TestCase { id: input; parent: bar.contentItem; name: "NotificationInput"; when: false }
    function find(item, name) {
        if ((item.objectName === name || item.text === name) && (String(item).indexOf("ActionButton") >= 0 || String(item).indexOf("TextField") >= 0 || item.objectName === name))
            return item;
        for (const child of item.children || []) {
            const match = find(child, name);
            if (match) return match;
        }
        return null;
    }
    IpcHandler {
        target: "uitest"
        function state(): string { return JSON.stringify({activeAddress:Hyprland.activeToplevel ? Hyprland.activeToplevel.address : "", settingsPath:Settings.path, settingsError:Settings.errorMessage, modules:Settings.rightModules, state:NotificationService.state, error:NotificationService.errorMessage, records:NotificationService.records, toasts:NotificationService.toasts, dnd:NotificationService.dnd, active:bar.activeSurface, pinned:SurfaceManager.notificationsPinned(bar.screenName), show:bar.shouldShow, right:bar.showRight}); }
        function open(pinned: bool): void { if(pinned) SurfaceManager.openNotifications(bar.screenName); else SurfaceManager.openOn("notifications", bar.screenName); }
        function fullscreen(): void { Hyprland.dispatch('hl.dsp.window.fullscreen({ action = "toggle", mode = "fullscreen" })'); }
        function toastCapture(path: string): void {
            const w = toastWindows.instances.find(w => w.visible);
            if(w) w.contentItem.children[0].grabToImage(result => result.saveToFile(path));
        }
        function windows(): string { return JSON.stringify(toastWindows.instances.map(w => ({screen:w.screenName, visible:w.visible, width:w.width, height:w.height, count:w.entries.length}))); }
        function close(): void { SurfaceManager.closeOn(bar.screenName); }
        function click(name: string): bool {
            const item = root.find(bar.contentItem, name);
            if (!item) return false;
            input.mouseClick(item, item.width / 2, item.height / 2);
            return true;
        }
        function key(key: int): void { input.keyClick(key); }
        function search(value: string): void {
            const item = root.find(bar.contentItem, "notificationSearch");
            if (item) item.text = value;
        }
        function focus(address: string): void { const w = Hyprland.toplevels.values.find(w => w.address === address.replace(/^0x/, "")); if(w && w.wayland) w.wayland.activate(); }
        function activate(uid: string): void { SurfaceManager.closeOn(bar.screenName); NotificationService.activate(uid, ""); }
        function clear(): void { NotificationService.clearAll(); }
        function capture(path: string): void { bar.contentItem.children[2].grabToImage(result => result.saveToFile(path)); }
        function tree(): string { return JSON.stringify(root.tree(bar.contentItem)); }
    }
}
