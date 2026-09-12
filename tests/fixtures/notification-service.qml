//@ pragma ShellId quickshell-notifications-test
import QtQuick
import Quickshell
import Quickshell.Io
import qs.services
import qs.core
ShellRoot {
    readonly property var service: NotificationService
    IpcHandler {
        target: "test"
        function stats(): string { return JSON.stringify({count: NotificationService.count, first: NotificationService.count ? NotificationService.records[0].summary : "", toasts: NotificationService.toasts.length}); }
        function state(): string { return JSON.stringify({state: NotificationService.state, error: NotificationService.errorMessage, records: NotificationService.records, toasts: NotificationService.toasts, dnd: NotificationService.dnd, hasNew: NotificationService.hasNew, undo: NotificationService.canUndo}); }
        function hide(uid: string): void { NotificationService.hideToast(uid); }
        function discard(uid: string): void { NotificationService.discard(uid); }
        function undo(): void { NotificationService.undo(); }
        function dnd(value: bool): void { NotificationService.setDnd(value); }
        function center(screen: string, value: bool): void { NotificationService.setCenterOpen(screen, value); }
        function pause(uid: string, value: bool): void { NotificationService.pauseToast(uid, value); }
        function activate(uid: string, action: string): void { NotificationService.activate(uid, action); }
        function clear(): void { NotificationService.clearAll(); }
        function groups(query: string): string { return JSON.stringify(NotificationService.groups(query)); }
        function limit(value: int): void { Settings.notificationHistoryLimit = value; }
        function duration(value: int): void { Settings.notificationToastDuration = value; }
    }
}
