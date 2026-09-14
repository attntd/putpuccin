import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io
import qs.core
import qs.services
import qs.modules.statusbar

ShellRoot {
    id: root
    property bool recordingFrames: false
    property var frameTimes: []
    Connections {
        target: loader.item ? loader.item.contentItem.Window.window : null
        function onFrameSwapped() {
            if (root.recordingFrames) root.frameTimes.push(Date.now());
        }
    }
    Window {
        id: application
        visible: true
        title: "Menu keyboard test application"
        width: 250
        height: 100
        TextInput { id: input; objectName: "testApplicationInput"; focus: true }
    }
    LazyLoader {
        id: loader
        active: !Settings.usingDefaults
        StatusBar { screen: Quickshell.screens[0] }
    }
    function descendants(item) {
        let items = [];
        for (const child of item.children || []) items = items.concat([child], descendants(child));
        return items;
    }
    IpcHandler {
        target: "menutest"
        function state(): string {
            if (!loader.item) return "{}";
            const bar = loader.item;
            const items = descendants(bar.contentItem);
            const focused = bar.contentItem.Window.activeFocusItem;
            const panels = items.filter(item => typeof item.focusDefaultControl === "function");
            const search = items.find(item => item.objectName === "notificationSearch");
            return JSON.stringify({active: bar.activeSurface, panels: panels.length,
                error: SurfaceManager.lastError,
                focused: focused ? focused.objectName || focused.text || "" : "",
                visualFocus: focused ? focused.visualFocus === true : false,
                activeFocus: focused ? focused.activeFocus : false,
                focusReason: focused ? focused.focusReason : -1,
                windowActive: bar.contentItem.Window.active,
                search: search ? search.text : "", dnd: NotificationService.dnd,
                bluetoothEnabled: BluetoothService.enabled,
                lockLabel: Strings.lock, logoutLabel: Strings.logout,
                applicationActive: application.active, applicationText: input.text,
                confirmation: panels.length ? panels[0].confirmation || "" : ""});
        }
        function focusApplication(): void { application.requestActivate(); input.forceActiveFocus(); }
        function beginFrames(): void { root.frameTimes = []; root.recordingFrames = true; }
        function endFrames(): string {
            root.recordingFrames = false;
            return JSON.stringify(root.frameTimes);
        }
        function reduced(value: bool): void { Settings.reducedMotion = value; }
        function close(): void { SurfaceManager.closeOn(loader.item.screenName); }
    }
}
