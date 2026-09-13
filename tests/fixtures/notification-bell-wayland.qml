import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.core
import qs.services
import qs.modules.statusbar
import qs.modules.notifications

ShellRoot {
    readonly property var bar: loader.item
    property var changes: []
    NotificationToasts { id: toasts; screen: Quickshell.screens[0] }
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
    function replyPoint(item, surface, corner) {
        if (!item) return null;
        const p = item.mapToItem(surface.contentItem, corner ? 20 : item.width / 2, corner ? 20 : item.height / 2);
        const x = surface === toasts ? surface.screen.width - surface.margins.right - surface.width : 0;
        const y = surface === toasts ? surface.margins.top : 0;
        return [Math.round(x + p.x), Math.round(y + p.y)];
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
        function replyState(): string {
            const surface = toasts.visible ? toasts : bar;
            const cards = descendants(surface.contentItem).filter(item => item.notification !== undefined
                && item.controlsRevealed !== undefined);
            return JSON.stringify({toast: toasts.visible, keyboard: toasts.WlrLayershell.keyboardFocus,
                clicked:toasts.clickedUid,
                none: WlrKeyboardFocus.None, exclusive: WlrKeyboardFocus.Exclusive,
                records: NotificationService.records.map(r => ({uid:r.uid, serverId:r.serverId})),
                cards: cards.map(card => {
                    const items = descendants(card);
                    const input = items.find(item => item.objectName === "notificationReplyInput");
                    const send = items.find(item => item.objectName === "notificationReplySend");
                    const cancel = items.find(item => item.objectName === "notificationReplyCancel");
                    const open = items.find(item => item.objectName === "notificationOpen");
                    const timer = NotificationService.toasts.find(t => t.uid === card.notification.uid);
                    return {uid:card.notification.uid, summary:card.notification.summary,
                        point:replyPoint(card, surface, true), height:card.height,
                        replyOpen:card.replyOpen === true, editor:!!input,
                        available:card.replyAvailable === true, controls:card.controlsRevealed,
                        draft:card.replyState ? card.replyState.text : "",
                        input:replyPoint(input, surface), focused:input ? input.activeFocus : false,
                        send:replyPoint(send, surface), sendEnabled:send ? send.enabled : false,
                        cancel:replyPoint(cancel, surface), open:replyPoint(open, surface),
                        paused:timer ? timer.paused : false};
                })});
        }
        function duration(value: int): void { Settings.notificationToastDuration = value; }
        function captureReply(path: string): void {
            const surface = toasts.visible ? toasts : bar;
            const card = descendants(surface.contentItem).find(item => item.replyOpen === true);
            if (card) card.grabToImage(result => result.saveToFile(path));
        }
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
