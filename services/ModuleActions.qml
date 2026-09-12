pragma Singleton

import Quickshell
import qs.core

Singleton {
    id: root

    readonly property var surfaceForModule: ({
        "power": "power",
        "launcher": "launcher",
        "clipboard": "clipboard",
        "context": "window",
        "media": "media",
        "quickSettings": "quickSettings",
        "audio": "audio",
        "brightness": "brightness",
        "network": "network",
        "bluetooth": "bluetooth",
        "battery": "battery",
        "clock": "calendar",
        "tray": "tray",
        "notifications": "notifications"
    })

    function optionKey(gesture) {
        return gesture === "primary" ? "primaryAction"
            : gesture === "secondary" ? "secondaryAction"
            : gesture === "scrollUp" ? "scrollUpAction" : "scrollDownAction";
    }

    function defaultAction(moduleId, gesture) {
        if (gesture === "primary") {
            if (moduleId === "notifications")
                return "activate";
            return root.surfaceForModule[moduleId] ? "openPopup" : "none";
        }
        if (gesture === "secondary") {
            if (moduleId === "audio")
                return "toggleMute";
            if (moduleId === "notifications")
                return "toggleDnd";
            return "none";
        }
        if (gesture === "scrollUp" && (moduleId === "audio" || moduleId === "brightness"))
            return "increase";
        if (gesture === "scrollDown" && (moduleId === "audio" || moduleId === "brightness"))
            return "decrease";
        return "none";
    }

    function run(moduleId, gesture, screenName) {
        const action = Settings.option(moduleId, root.optionKey(gesture), root.defaultAction(moduleId, gesture));
        if (action === "none")
            return;
        if (action === "openPopup") {
            const surface = root.surfaceForModule[moduleId];
            if (surface)
                SurfaceManager.toggleOn(surface, screenName);
            return;
        }
        if (action === "toggleMute") {
            AudioService.toggleMute();
            return;
        }
        if (action === "increase" || action === "decrease") {
            const direction = action === "increase" ? 1 : -1;
            if (moduleId === "brightness")
                BrightnessService.adjust(direction * Settings.brightnessStep);
            else
                AudioService.adjustVolume(direction * Settings.volumeStep / 100);
            return;
        }
        if (action === "toggleDnd") {
            NotificationService.toggleDnd();
            return;
        }
        if (action === "launchFallback") {
            if (moduleId === "network")
                NetworkService.openAdvanced(screenName);
            else if (moduleId === "bluetooth")
                SurfaceManager.openOn("bluetooth", screenName);
            return;
        }
        if (action === "activate") {
            if (moduleId === "launcher")
                SurfaceManager.openDetachedLauncher();
            else if (moduleId === "notifications")
                SurfaceManager.toggleNotifications(screenName);
            return;
        }
        if (action === "secondaryActivate" && moduleId === "notifications")
            NotificationService.toggleDnd();
    }
}
