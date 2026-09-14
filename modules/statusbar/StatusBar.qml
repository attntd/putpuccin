import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.core
import qs.services

PanelWindow {
    id: barWindow

    readonly property bool shouldShow: SurfaceManager.barVisible
        && !(Settings.hideOnFullscreen && HyprlandService.hasFullscreen(screen))
    readonly property string screenName: HyprlandService.screenName(screen)
    readonly property string activeSurface: SurfaceManager.activeSurface(screenName)
    property int captureToken: -1
    property bool presentedExpanded: false
    readonly property bool captureExpanded: leftIsland.height > Settings.barHeight
        || centerIsland.height > Settings.barHeight || rightIsland.height > Settings.barHeight
        || leftIsland.expansionProgress > 0 || centerIsland.expansionProgress > 0
        || rightIsland.expansionProgress > 0
    Connections {
        target: ScreenshotService
        function onCaptureStarting(token) {
            if (barWindow.presentedExpanded || barWindow.captureExpanded) {
                barWindow.captureToken = token;
                ScreenshotService.holdCapture("bar:" + barWindow.screenName, token);
            }
        }
    }
    Connections {
        target: barWindow.contentItem.Window.window
        function onFrameSwapped() {
            barWindow.presentedExpanded = barWindow.captureExpanded;
            if (barWindow.captureToken >= 0 && !barWindow.captureExpanded) {
                const token = barWindow.captureToken;
                barWindow.captureToken = -1;
                ScreenshotService.releaseCapture("bar:" + barWindow.screenName, token);
            }
        }
    }

    property bool launcherSearchActive: false
    property bool clipboardSearchActive: false
    property bool notificationSearchActive: false
    readonly property bool showRight: shouldShow || activeSurface === "notifications"
    readonly property bool keyboardSurfaceActive: activeSurface.length > 0
    readonly property real centerCapacity: Math.max(0, 2 * Math.min(
        width / 2 - (leftIsland.x + leftIsland.width) - Metrics.barGap,
        rightIsland.x - width / 2 - Metrics.barGap))

    anchors {
        top: true
        left: true
        right: true
    }
    // Keep the layer-surface buffer stable while islands animate. Only the
    // masked rectangles below are interactive, so the transparent remainder
    // neither blocks windows nor participates in the visible expansion.
    implicitHeight: Math.max(0, (screen ? screen.height : 900) - Settings.topMargin)
    color: "transparent"
    exclusiveZone: shouldShow ? Settings.reservedHeight : 0
    WlrLayershell.namespace: "quickshell-de:statusbar"
    WlrLayershell.layer: !shouldShow && activeSurface === "notifications" ? WlrLayer.Overlay : WlrLayer.Top
    // The island grab focuses these menus, including their text editors.
    // Switching to Exclusive would clear that grab and close the panel.
    WlrLayershell.keyboardFocus: ["power", "notifications", "bluetooth", "quickSettings"].indexOf(activeSurface) >= 0
        ? WlrKeyboardFocus.OnDemand
        : (shouldShow && activeSurface === "launcher" && launcherSearchActive)
        || (shouldShow && activeSurface === "clipboard" && clipboardSearchActive)
        ? WlrKeyboardFocus.Exclusive : keyboardSurfaceActive
        ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

    function activateLauncherSearch() {
        if (shouldShow && activeSurface === "launcher")
            launcherSearchActive = true;
    }

    function activateClipboardSearch() {
        if (shouldShow && activeSurface === "clipboard" && !clipboardSearchActive) {
            ClipboardService.rememberFocus();
            clipboardSearchActive = true;
        }
    }

    function activateNotificationSearch() {
        if (activeSurface === "notifications")
            notificationSearchActive = true;
    }

    function closeHiddenSurface() {
        // The notification overlay intentionally remains available above a
        // fullscreen window. Other hidden panels must release their resources.
        if (!activeSurface || activeSurface === "notifications")
            return;
        if (!shouldShow || (centerCapacity < 180 && centerIsland.hostForSurface(activeSurface)))
            SurfaceManager.closeOn(screenName);
    }

    onActiveSurfaceChanged: {
        launcherSearchActive = false;
        clipboardSearchActive = false;
        notificationSearchActive = false;
        Qt.callLater(closeHiddenSurface);
    }
    onShouldShowChanged: {
        if (!shouldShow) {
            launcherSearchActive = false;
            clipboardSearchActive = false;
        }
        Qt.callLater(closeHiddenSurface);
    }
    onCenterCapacityChanged: if (centerCapacity < 180) Qt.callLater(closeHiddenSurface)

    Component.onDestruction: SurfaceManager.forgetScreen(screenName)

    mask: Region {
        Region {
            x: leftIsland.x
            y: leftIsland.y
            width: barWindow.shouldShow ? leftIsland.width : 0
            height: leftIsland.height
            radius: leftIsland.radius
        }
        Region {
            x: centerIsland.x
            y: centerIsland.y
            width: barWindow.shouldShow && barWindow.centerCapacity >= 180 ? centerIsland.width : 0
            height: centerIsland.height
            radius: centerIsland.radius
        }
        Region {
            x: rightIsland.x
            y: rightIsland.y
            width: barWindow.showRight ? rightIsland.width : 0
            height: rightIsland.height
            radius: rightIsland.radius
        }
    }

    BarIsland {
        id: leftIsland
        expansionEnabled: barWindow.shouldShow
        x: Settings.sideMargin
        y: Settings.topMargin
        moduleIds: Settings.leftModules
        barWindow: barWindow
        shellScreen: barWindow.screen
        contentAlignment: Qt.AlignLeft
        opacity: barWindow.shouldShow ? 1 : 0
        visible: opacity > 0
        transform: AnimatedTranslate { y: barWindow.shouldShow ? 0 : -Settings.barHeight }
    }

    BarIsland {
        id: centerIsland
        expansionEnabled: barWindow.shouldShow && barWindow.centerCapacity >= 180
        anchors.horizontalCenter: parent.horizontalCenter
        y: Settings.topMargin
        moduleIds: Settings.centerModules
        compactModuleId: "context"
        barWindow: barWindow
        shellScreen: barWindow.screen
        maximumContentWidth: barWindow.centerCapacity
        animateWidth: false
        animateExpansionWidth: true
        contentAlignment: Qt.AlignHCenter
        opacity: barWindow.shouldShow && barWindow.centerCapacity >= 180 ? 1 : 0
        visible: opacity > 0
        transform: AnimatedTranslate { y: barWindow.shouldShow ? 0 : -Settings.barHeight }
    }

    BarIsland {
        id: rightIsland
        expansionEnabled: barWindow.showRight
        x: barWindow.width - width - Settings.sideMargin
        y: Settings.topMargin
        minimumExpansionWidth: Metrics.popupWidth
        moduleIds: Settings.rightModules
        barWindow: barWindow
        shellScreen: barWindow.screen
        contentAlignment: Qt.AlignRight
        opacity: barWindow.showRight ? 1 : 0
        visible: opacity > 0
        transform: AnimatedTranslate { y: barWindow.showRight ? 0 : -Settings.barHeight }
    }

    component AnimatedTranslate: Translate {
        Behavior on y {
            NumberAnimation {
                duration: Settings.reducedMotion ? 0 : Motion.standard
                easing.type: Easing.OutCubic
            }
        }
    }
}
