import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.core
import qs.services

Scope {
    // One shared directory model and clock, with a render surface per monitor.
    readonly property var service: WallpaperService

    Variants {
        model: Settings.wallpaperEnabled ? Quickshell.screens : []

        PanelWindow {
            id: window
            required property var modelData
            screen: modelData
            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: WlrLayer.Background
            WlrLayershell.namespace: "quickshell-de:wallpaper"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            mask: Region {}
            color: Theme.base

            WallpaperView {
                anchors.fill: parent
                source: WallpaperService.currentSource
                pixelRatio: window.devicePixelRatio
                onLoadFailed: source => WallpaperService.reject(source)
            }
        }
    }
}
