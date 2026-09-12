pragma ComponentBehavior: Bound

import QtQuick
import qs.components
import qs.core
import qs.popups
import qs.services

Item {
    id: root
    property var barWindow
    property var shellScreen
    readonly property string screenName: HyprlandService.screenName(shellScreen)
    readonly property string expansionSurface: "clipboard"
    readonly property int expansionWidth: Metrics.popupWidth
    readonly property Component expansionComponent: clipboardExpansion
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    BarButton {
        id: button
        anchors.fill: parent
        icon: ClipboardService.paused ? Icons.pauseCircle : Icons.clipboard
        iconForeground: Theme.text
        text: Settings.option("clipboard", "presentation", "adaptive") === "label" ? Strings.clipboard : ""
        compact: Settings.option("clipboard", "presentation", "adaptive") !== "label"
        warning: ClipboardService.state === "error" || ClipboardService.state === "unavailable"
        active: SurfaceManager.isOpen("clipboard", root.screenName)
        tooltip: ClipboardService.paused ? Strings.clipboardPaused : Strings.clipboard
        onClicked: {
            ClipboardService.rememberFocus();
            ModuleActions.run("clipboard", "primary", root.screenName);
        }
        onRightClicked: ModuleActions.run("clipboard", "secondary", root.screenName)
    }

    Component {
        id: clipboardExpansion
        ClipboardPopup {
            screenName: root.screenName
            embedded: true
            onSearchFocusRequested: root.barWindow.activateClipboardSearch()
        }
    }
}
