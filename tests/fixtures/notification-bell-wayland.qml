import QtQuick
import Quickshell
import Quickshell.Io
import qs.core
import qs.services
import qs.modules.statusbar

ShellRoot {
    readonly property var bar: loader.item
    property var changes: []
    LazyLoader {
        id: loader
        active: !Settings.usingDefaults
        StatusBar { screen: Quickshell.screens[0] }
    }
    Connections {
        target: SurfaceManager
        function onChanged(screen, surface) { changes = changes.concat([surface]); }
    }

    function descendants(item) {
        let result = [];
        for (const child of item.children || [])
            result = result.concat([child], descendants(child));
        return result;
    }
    function island() {
        if (!bar) return null;
        return descendants(bar.contentItem).find(item => item.moduleIds
            && item.moduleIds.indexOf("notifications") >= 0);
    }
    function button() {
        const host = island().hostForSurface("notifications");
        return host && descendants(host).find(item => item.iconForeground !== undefined);
    }
    function point(item) {
        if (!item) return null;
        const p = item.mapToItem(bar.contentItem, item.width / 2, item.height / 2);
        return [Math.round(p.x), Math.round(p.y)];
    }

    IpcHandler {
        target: "belltest"
        function ready(): bool { return !!island() && !!button() && NotificationService.available; }
        function state(): string {
            const items = descendants(bar.contentItem);
            const input = items.find(item => item.objectName === "notificationSearch");
            const panel = items.find(item => item.maximumHeight !== undefined && item.hasHistory !== undefined);
            return JSON.stringify({
                open: island().expanded, panel: !!panel,
                height: island().height, active: bar.activeSurface,
                changes: changes,
                pinned: SurfaceManager.notificationsPinned(bar.screenName),
                bell: point(button()), color: button().iconForeground.toString(),
                icon: button().icon, ordinaryIcon: Icons.notification, dndIcon: Icons.notificationOff,
                count: NotificationService.count, hasNew: NotificationService.hasNew,
                dnd: NotificationService.dnd, text: Theme.text.toString(),
                accent: Theme.accent.toString(), red: Theme.red.toString(),
                badge: items.some(item => item.objectName === "notificationBadge" && item.visible),
                search: point(input), query: input ? input.text : "",
                focused: input ? input.activeFocus : false
            });
        }
        function clear(): void { NotificationService.clearAll(); }
        function close(): void { SurfaceManager.closeOn(bar.screenName); }
        function dnd(value: bool): void { NotificationService.setDnd(value); }
        function reduced(value: bool): void { Settings.reducedMotion = value; }
        function fullscreen(value: bool): void { HyprlandService.fullscreen = value; }
        function primary(action: string): void {
            Settings.moduleOptions = {notifications: {primaryAction: action}};
        }
        function open(): void { SurfaceManager.openNotifications(bar.screenName); }
        function capture(path: string): void { island().grabToImage(result => result.saveToFile(path)); }
    }
}
