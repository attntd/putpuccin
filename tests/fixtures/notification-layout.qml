// Native layer-shell regression: startup must converge before the first map.
import QtQuick
import QtQuick.Window
import QtTest
import Quickshell
import Quickshell.Io
import qs.core
import qs.services
import qs.modules.notifications
ShellRoot {
    id: root
    function find(item, name) {
        if (item.objectName === name) return item;
        for (const child of item.children || []) {
            const found = find(child, name);
            if (found) return found;
        }
        return null;
    }
    NotificationToasts { id: toasts; screen: Quickshell.screens[0] }
    TestCase { id: input; parent: toasts.contentItem; when: false }
    IpcHandler {
        target: "layouttest"
        function clickControls(): bool {
            let card = root.find(toasts.contentItem, "notificationExpand");
            while (card && card.notification === undefined) card = card.parent;
            if (!card) return false;
            input.mouseMove(card, 2, 2); input.wait(240);
            if (card.controlsRevealed || toasts.clickedUid) return false;
            input.mouseClick(card, 2, 2); input.wait(240);
            if (!card.controlsRevealed || toasts.clickedUid !== "layout-test") return false;
            input.mouseMove(toasts.contentItem, 0, toasts.height - 1); input.wait(240);
            const retained = card.controlsRevealed;
            toasts.clickedUid = "";
            return retained;
        }
        function configure(width: int, longText: bool, shown: bool): void {
            Settings.notificationWidth = width;
            NotificationService.longText = longText;
            NotificationService.shown = shown;
        }
        function expand(value: bool): void {
            let card = root.find(toasts.contentItem, "notificationExpand");
            while (card && card.notification === undefined) card = card.parent;
            if (card) card.expanded = value;
        }
        function status(): string {
            const button = root.find(toasts.contentItem, "notificationExpand");
            return JSON.stringify({shown:toasts.visible, width:toasts.width,
                buttonPresent:!!button, arrowVisible:button ? button.visible : false,
                arrowEnabled:button ? button.enabled : false});
        }
    }
}
