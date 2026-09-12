pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.services

Singleton {
    id: root

    readonly property var knownSurfaces: [
        "power", "launcher", "window", "clipboard", "media", "tray", "audio", "brightness", "quickSettings",
        "network", "bluetooth", "battery", "calendar", "notifications"
    ]
    property var pinnedNotifications: ({})
    property var activeByScreen: ({})
    property bool detachedLauncherVisible: false
    property string detachedLauncherScreenName: ""
    property bool barVisible: true
    property string lastError: ""
    property int revision: 0
    readonly property bool workspaceSwitcherHeld: switcherLeft.pressed || switcherRight.pressed
    property bool workspaceSwitcherVisible: false
    property string workspaceSwitcherScreenName: ""

    onWorkspaceSwitcherHeldChanged: {
        if (!workspaceSwitcherHeld)
            workspaceSwitcherVisible = false;
    }

    function cycleWorkspaceSwitcher() {
        if (AuthenticationService.interactive) return;
        if (!root.workspaceSwitcherVisible) {
            root.workspaceSwitcherVisible = true;
            return;
        }
        const occupied = Hyprland.workspaces.values
            .filter(workspace => workspace.id > 0 && workspace.toplevels.values.length > 0)
            .sort((a, b) => a.id - b.id);
        if (!occupied.length)
            return;
        const current = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : 0;
        const next = occupied.find(workspace => workspace.id > current) || occupied[0];
        next.activate();
    }

    onWorkspaceSwitcherVisibleChanged: {
        if (workspaceSwitcherVisible) {
            if (ScreenshotService.active)
                ScreenshotService.cancel();
            root.closeAllInternal();
            root.workspaceSwitcherScreenName = root.focusedScreenName();
        } else {
            root.workspaceSwitcherScreenName = "";
        }
    }

    GlobalShortcut {
        id: switcherLeft
        appid: "quickshell-de"
        name: "workspace-switcher-left"
        description: Strings.workspaceSwitcher
    }
    GlobalShortcut {
        id: switcherRight
        appid: "quickshell-de"
        name: "workspace-switcher-right"
        description: Strings.workspaceSwitcher
    }
    GlobalShortcut {
        appid: "quickshell-de"
        name: "workspace-switcher-next"
        description: Strings.workspaceSwitcher
        onPressed: root.cycleWorkspaceSwitcher()
    }
    Connections {
        target: Hyprland
        function onFocusedMonitorChanged() {
            if (root.workspaceSwitcherVisible)
                root.workspaceSwitcherScreenName = root.focusedScreenName();
        }
    }
    Connections {
        target: ScreenshotService
        function onActiveChanged() {
            if (!ScreenshotService.active)
                return;
            if (root.workspaceSwitcherVisible || root.detachedLauncherVisible) {
                screenshotExit.token = ScreenshotService.generation;
                ScreenshotService.holdCapture("overlay-exit", screenshotExit.token);
                screenshotExit.restart();
            }
            root.workspaceSwitcherVisible = false;
            root.closeAllInternal();
        }
    }
    Timer {
        id: screenshotExit
        property int token: -1
        // These layer surfaces fade in Hyprland after unmapping; Qt's hide
        // signal cannot confirm compositor animation completion. This fallback
        // runs only when closing an actual launcher or workspace switcher.
        interval: 280
        onTriggered: ScreenshotService.releaseCapture("overlay-exit", token)
    }
    Connections {
        target: ScreenshotService
        function onActiveChanged() { if (!ScreenshotService.active) screenshotExit.stop(); }
    }

    signal changed(string screenName, string surfaceId)

    function focusedScreenName() {
        return Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : "";
    }

    function valid(surfaceId) {
        return root.knownSurfaces.indexOf(surfaceId) >= 0;
    }

    function activeSurface(screenName) {
        root.revision;
        return root.activeByScreen[screenName] || "";
    }

    function isOpen(surfaceId, screenName) {
        root.revision;
        return root.activeByScreen[screenName] === surfaceId;
    }

    function notificationsPinned(screenName) {
        root.revision;
        return root.pinnedNotifications[screenName] === true && isOpen("notifications", screenName);
    }

    function pinNotifications(screenName) {
        const map = Object.assign({}, pinnedNotifications);
        map[screenName] = true;
        pinnedNotifications = map;
        revision++;
    }

    function openNotifications(screenName) {
        const screen = screenName || focusedScreenName();
        if (openOn("notifications", screen))
            pinNotifications(screen);
    }

    function toggleNotifications(screenName) {
        const screen = screenName || focusedScreenName();
        if (notificationsPinned(screen))
            closeOn(screen);
        else
            openNotifications(screen);
    }

    function openOn(surfaceId, screenName, fromHover) {
        if (AuthenticationService.interactive) return false;
        // Older callers cannot reopen panels from pointer movement.
        if (fromHover === true)
            return false;
        if (!root.valid(surfaceId)) {
            root.lastError = "Nieznana powierzchnia: " + surfaceId;
            return false;
        }
        const targetScreen = screenName || root.focusedScreenName();
        if (!targetScreen) {
            root.lastError = "Nie można ustalić aktywnego monitora.";
            return false;
        }
        if (ScreenshotService.active)
            ScreenshotService.cancel();
        root.closeDetachedLauncher();
        const next = Object.assign({}, root.activeByScreen);
        if (surfaceId !== "notifications") {
            const pins = Object.assign({}, pinnedNotifications);
            delete pins[targetScreen];
            pinnedNotifications = pins;
        }
        next[targetScreen] = surfaceId;
        root.activeByScreen = next;
        root.lastError = "";
        root.revision++;
        root.changed(targetScreen, surfaceId);
        return true;
    }

    function toggleOn(surfaceId, screenName) {
        const targetScreen = screenName || root.focusedScreenName();
        if (root.isOpen(surfaceId, targetScreen)) {
            root.closeOn(targetScreen);
            return true;
        }
        return root.openOn(surfaceId, targetScreen);
    }

    function closeOn(screenName) {
        if (!screenName || !root.activeByScreen[screenName])
            return;
        const next = Object.assign({}, root.activeByScreen);
        delete next[screenName];
        const pins = Object.assign({}, pinnedNotifications);
        delete pins[screenName];
        pinnedNotifications = pins;
        root.activeByScreen = next;
        root.revision++;
        root.changed(screenName, "");
    }

    function prepareSettingsWindow(screenName) {
        if (AuthenticationService.interactive) return false;
        if (ScreenshotService.active) ScreenshotService.cancel();
        root.closeDetachedLauncher();
        root.closeOn(screenName);
        return true;
    }

    function forgetScreen(screenName) {
        if (!screenName)
            return;
        const next = Object.assign({}, root.activeByScreen);
        const pins = Object.assign({}, root.pinnedNotifications);
        delete next[screenName];
        delete pins[screenName];
        root.activeByScreen = next;
        root.pinnedNotifications = pins;
        if (root.detachedLauncherScreenName === screenName) {
            root.detachedLauncherVisible = false;
            root.detachedLauncherScreenName = "";
        }
        if (root.workspaceSwitcherScreenName === screenName) {
            root.workspaceSwitcherVisible = false;
            root.workspaceSwitcherScreenName = "";
        }
        root.revision++;
        root.changed(screenName, "");
    }

    function openDetachedLauncher() {
        if (AuthenticationService.interactive) return false;
        const targetScreen = root.focusedScreenName();
        if (!targetScreen) {
            root.lastError = "Nie można ustalić aktywnego monitora.";
            return false;
        }
        if (ScreenshotService.active)
            ScreenshotService.cancel();
        root.workspaceSwitcherVisible = false;
        root.pinnedNotifications = {};
        root.activeByScreen = {};
        root.detachedLauncherScreenName = targetScreen;
        root.detachedLauncherVisible = true;
        root.lastError = "";
        root.revision++;
        root.changed(targetScreen, "launcher");
        return true;
    }

    function closeDetachedLauncher() {
        if (!root.detachedLauncherVisible)
            return;
        const screenName = root.detachedLauncherScreenName;
        root.detachedLauncherVisible = false;
        root.detachedLauncherScreenName = "";
        root.revision++;
        root.changed(screenName, "");
    }

    function toggleDetachedLauncher() {
        if (root.detachedLauncherVisible) {
            root.closeDetachedLauncher();
            return true;
        }
        return root.openDetachedLauncher();
    }

    function closeLauncher(screenName) {
        root.closeOn(screenName);
        root.closeDetachedLauncher();
    }

    function closeAllInternal() {
        root.pinnedNotifications = {};
        root.activeByScreen = {};
        root.detachedLauncherVisible = false;
        root.detachedLauncherScreenName = "";
        root.revision++;
        root.changed("", "");
    }

    IpcHandler {
        target: "workspaceSwitcher"
        function status(): string {
            return JSON.stringify({visible: root.workspaceSwitcherVisible,
                screen: root.workspaceSwitcherScreenName,
                left: switcherLeft.pressed, right: switcherRight.pressed});
        }
    }

    IpcHandler {
        target: "surfaces"

        function open(surfaceId: string): void {
            root.openOn(surfaceId, "");
        }

        function toggle(surfaceId: string): void {
            root.toggleOn(surfaceId, "");
        }

        function closeAll(): void {
            if (ScreenshotService.active)
                ScreenshotService.cancel();
            root.workspaceSwitcherVisible = false;
            root.closeAllInternal();
        }

        function active(): string {
            return root.activeSurface(root.focusedScreenName());
        }
    }

    IpcHandler {
        target: "launcher"

        function open(): void {
            root.openDetachedLauncher();
        }

        function toggle(): void {
            root.toggleDetachedLauncher();
        }

        function close(): void {
            root.closeDetachedLauncher();
        }
    }

    IpcHandler {
        target: "notifications"
        function open(): void { root.openNotifications(""); }
        function toggle(): void { root.toggleNotifications(""); }
        function close(): void {
            for (const screen in root.activeByScreen)
                if (root.isOpen("notifications", screen)) root.closeOn(screen);
        }
        function toggleDnd(): void { NotificationService.toggleDnd(); }
    }

    IpcHandler {
        target: "bar"

        function setVisible(visible: bool): void {
            root.barVisible = visible;
            if (!visible)
                root.closeAllInternal();
        }

        function visible(): bool {
            return root.barVisible;
        }
    }
}
