import QtQuick
import qs.core

Item {
    id: root

    required property string moduleId
    required property var barWindow
    required property var shellScreen

    // Each entry remains an independent, reorderable toolbar module.
    readonly property var sources: ({
        "power": "PowerModule.qml",
        "launcher": "LauncherModule.qml",
        "workspaces": "WorkspacesModule.qml",
        "context": "ContextModule.qml",
        "media": "MediaModule.qml",
        "clipboard": "ClipboardModule.qml",
        "tray": "TrayModule.qml",
        "quickSettings": "QuickSettingsModule.qml",
        "audio": "AudioModule.qml",
        "brightness": "BrightnessModule.qml",
        "network": "NetworkModule.qml",
        "bluetooth": "BluetoothModule.qml",
        "battery": "BatteryModule.qml",
        "notifications": "NotificationsModule.qml",
        "clock": "ClockModule.qml"
    })
    readonly property Item loadedItem: moduleLoader.item as Item
    readonly property string expansionSurface: loadedItem ? (loadedItem.expansionSurface || "") : ""
    readonly property int expansionWidth: loadedItem ? (loadedItem.expansionWidth || 0) : 0
    readonly property Component expansionComponent: loadedItem ? (loadedItem.expansionComponent || null) : null
    signal moduleReady()

    implicitWidth: loadedItem ? loadedItem.implicitWidth : 0
    implicitHeight: loadedItem ? loadedItem.implicitHeight : 0
    visible: moduleLoader.status === Loader.Ready

    Loader {
        id: moduleLoader
        anchors.fill: parent
        source: root.sources[root.moduleId] || ""

        onLoaded: {
            item.barWindow = root.barWindow;
            item.shellScreen = root.shellScreen;
            root.moduleReady();
        }
    }
}
