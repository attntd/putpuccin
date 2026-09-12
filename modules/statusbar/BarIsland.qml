pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Hyprland
import qs.core
import qs.services

Rectangle {
    id: root

    required property var moduleIds
    required property var barWindow
    required property var shellScreen
    property int maximumContentWidth: 10000
    property bool animateWidth: true
    property bool animateExpansionWidth: false
    property bool expansionEnabled: true
    property string compactModuleId: ""
    readonly property bool hasCompactModule: compactModuleId.length > 0
        && moduleIds.indexOf(compactModuleId) >= 0
    readonly property bool modulesRevealed: !hasCompactModule || expanded
    property real moduleRevealProgress: modulesRevealed ? 1 : 0
    property int contentAlignment: Qt.AlignLeft
    property Component expansionComponent: null
    property string expansionSurface: ""
    property int expansionWidth: 0
    property var expansionHost: null
    property int minimumExpansionWidth: 0
    property real expansionHeight: 0
    readonly property string screenName: HyprlandService.screenName(shellScreen)
    readonly property string activeSurface: SurfaceManager.activeSurface(screenName)
    readonly property bool expanded: expansionEnabled && activeSurface === expansionSurface
        && expansionSurface.length > 0 && expansionComponent !== null
    readonly property int collapsedWidth: row.implicitWidth + Metrics.space8
    property real expansionProgress: expanded ? 1 : 0
    readonly property real targetWidth: animateExpansionWidth
        ? collapsedWidth + expansionProgress * Math.max(0, expansionWidth - collapsedWidth)
        : Math.max(collapsedWidth, expanded ? expansionWidth : 0)
    readonly property real targetHeight: Settings.barHeight
        + (expanded ? expansionHeight : 0)

    implicitWidth: Math.min(maximumContentWidth, targetWidth)
    implicitHeight: targetHeight
    // Keep the right-aligned header's local pixel phase stable while resizing.
    width: Math.round(implicitWidth)
    height: Math.round(implicitHeight)
    // The header centers inside this item. Rounding the outer center as well
    // moves its contents by half a pixel whenever the island width changes parity.
    anchors.alignWhenCentered: contentAlignment !== Qt.AlignHCenter
    radius: Metrics.barRadius
    color: Theme.withAlpha(Theme.base, Settings.barSurfaceOpacity)
    clip: true
    // Isolate header and panel below, instead of resampling the whole island
    // texture on every animated resize (which shifts stationary controls).

    function hostForSurface(surfaceId) {
        for (let index = 0; index < moduleRepeater.count; index++) {
            const host = moduleRepeater.itemAt(index);
            if (host && host.expansionSurface === surfaceId)
                return host;
        }
        return null;
    }

    function syncExpansion() {
        const host = root.hostForSurface(root.activeSurface);
        root.expansionHost = host;
        if (!host) {
            root.expansionSurface = "";
            root.expansionComponent = null;
            root.expansionHeight = 0;
            return;
        }
        // A shared island can keep its panel width even when a module still
        // requests a narrower standalone popup (for example tray overflow).
        root.expansionWidth = Math.max(root.minimumExpansionWidth, host.expansionWidth);
        root.expansionSurface = host.expansionSurface;
        root.expansionComponent = host.expansionComponent;
    }

    function syncExpansionHeight() {
        // Changing Loader.sourceComponent briefly resets its implicit height to
        // zero. Keep the previous panel height until the next one is ready so
        // switching modules cannot collapse and reopen the whole island.
        if (expansionLoader.status === Loader.Ready && expansionLoader.item
                && expansionLoader.implicitHeight > 0)
            root.expansionHeight = expansionLoader.implicitHeight;
    }

    onActiveSurfaceChanged: syncExpansion()
    Component.onCompleted: Qt.callLater(syncExpansion)

    Connections {
        target: root.expansionHost
        function onExpansionWidthChanged() {
            if (root.expansionHost)
                root.expansionWidth = Math.max(root.minimumExpansionWidth, root.expansionHost.expansionWidth);
        }
    }

    HyprlandFocusGrab {
        windows: root.barWindow && root.barWindow.contentItem ? [root.barWindow] : []
        active: root.expanded && windows.length > 0
        onCleared: if (root.expanded) SurfaceManager.closeOn(root.screenName)
    }

    Shortcut {
        sequence: "Escape"
        enabled: root.expanded
        onActivated: SurfaceManager.closeOn(root.screenName)
    }

    Row {
        id: row
        // A compact header changes width during reveal. Keep each module's
        // texture separate so resizing the row cannot resample the title.
        layer.enabled: !root.hasCompactModule
        layer.smooth: true
        x: root.contentAlignment === Qt.AlignRight
            ? root.width - implicitWidth - Metrics.space4
            : root.contentAlignment === Qt.AlignHCenter
                ? (root.width - implicitWidth) / 2 : Metrics.space4
        y: Metrics.space4
        spacing: (root.hasCompactModule ? Metrics.space8 : Metrics.space2)
            * root.moduleRevealProgress

        Repeater {
            id: moduleRepeater
            model: root.moduleIds

            BarModuleHost {
                required property string modelData
                readonly property bool secondaryModule: root.hasCompactModule
                    && modelData !== root.compactModuleId
                moduleId: modelData
                barWindow: root.barWindow
                shellScreen: root.shellScreen
                // Row preserves fractional positions; RowLayout rounds each
                // child's geometry independently and makes the centered title jitter.
                width: implicitWidth * (secondaryModule ? root.moduleRevealProgress : 1)
                height: implicitHeight
                y: (row.height - height) / 2
                layer.enabled: root.hasCompactModule
                layer.smooth: true
                opacity: secondaryModule ? root.moduleRevealProgress : 1
                enabled: !secondaryModule || root.modulesRevealed
                clip: secondaryModule && root.moduleRevealProgress < 1
                onModuleReady: root.syncExpansion()
            }
        }
    }

    Loader {
        id: expansionLoader
        layer.enabled: true
        layer.smooth: true
        active: root.expanded
        sourceComponent: root.expansionComponent
        x: Metrics.space4
        y: Settings.barHeight
        width: Math.max(0, root.width - Metrics.space8)
        opacity: root.expanded ? 1 : 0

        onLoaded: root.syncExpansionHeight()
        onImplicitHeightChanged: root.syncExpansionHeight()

        Behavior on opacity {
            NumberAnimation { duration: Settings.reducedMotion ? 0 : Motion.fast }
        }
    }

    Behavior on implicitWidth {
        enabled: root.animateWidth
        NumberAnimation {
            duration: Settings.reducedMotion ? 0 : Motion.standard
            easing.type: Easing.OutCubic
        }
    }

    Behavior on expansionProgress {
        enabled: root.animateExpansionWidth
        NumberAnimation {
            duration: Settings.reducedMotion ? 0 : Motion.standard
            easing.type: Easing.OutCubic
        }
    }

    Behavior on expansionWidth {
        // Opening/closing already uses expansionProgress. This transition is
        // for another panel or new metadata while the center stays expanded.
        enabled: root.animateExpansionWidth && root.expansionProgress === 1
        NumberAnimation {
            duration: Settings.reducedMotion ? 0 : Motion.standard
            easing.type: Easing.OutCubic
        }
    }

    Behavior on moduleRevealProgress {
        NumberAnimation {
            duration: Settings.reducedMotion ? 0 : Motion.standard
            easing.type: Easing.OutCubic
        }
    }

    Behavior on opacity {
        NumberAnimation { duration: Settings.reducedMotion ? 0 : Motion.standard }
    }

    Behavior on implicitHeight {
        NumberAnimation {
            duration: Settings.reducedMotion ? 0 : Motion.standard
            easing.type: Easing.OutCubic
        }
    }
}
