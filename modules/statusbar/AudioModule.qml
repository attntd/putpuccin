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
    readonly property string expansionSurface: "audio"
    readonly property int expansionWidth: 380
    readonly property Component expansionComponent: audioExpansion
    readonly property int stableButtonWidth: Math.ceil(Math.max(
        volumeMutedMetrics.advanceWidth,
        volumeOffMetrics.advanceWidth,
        volumeLowMetrics.advanceWidth,
        volumeHighMetrics.advanceWidth
    ) + Metrics.space6 + percentageMetrics.advanceWidth + Metrics.space12)
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    TextMetrics {
        id: volumeMutedMetrics
        text: Icons.volumeMuted
        font.family: Metrics.fontFamily
        font.pixelSize: Metrics.iconMedium
    }

    TextMetrics {
        id: volumeOffMetrics
        text: Icons.volumeOff
        font.family: Metrics.fontFamily
        font.pixelSize: Metrics.iconMedium
    }

    TextMetrics {
        id: volumeLowMetrics
        text: Icons.volumeLow
        font.family: Metrics.fontFamily
        font.pixelSize: Metrics.iconMedium
    }

    TextMetrics {
        id: volumeHighMetrics
        text: Icons.volumeHigh
        font.family: Metrics.fontFamily
        font.pixelSize: Metrics.iconMedium
    }

    TextMetrics {
        id: percentageMetrics
        text: "100%"
        font.family: Metrics.fontFamily
        font.pixelSize: Metrics.fontSmall
        font.weight: Font.DemiBold
    }

    BarButton {
        id: button
        anchors.fill: parent
        implicitWidth: compact ? Metrics.minHitSize : root.stableButtonWidth
        icon: AudioService.muted ? Icons.volumeMuted : AudioService.volume > 0.5 ? Icons.volumeHigh : Icons.volumeLow
        foreground: Theme.rosewater
        text: Math.round(AudioService.volume * 100) + "%"
        compact: Settings.option("audio", "presentation", "adaptive") === "icon"
        warning: !AudioService.available
        active: SurfaceManager.isOpen("audio", root.screenName)
        tooltip: AudioService.available ? AudioService.description : Strings.unavailable
        onClicked: ModuleActions.run("audio", "primary", root.screenName)
        onMiddleClicked: ModuleActions.run("audio", "secondary", root.screenName)
        onRightClicked: ModuleActions.run("audio", "secondary", root.screenName)
        onWheel: delta => ModuleActions.run("audio", delta > 0 ? "scrollUp" : "scrollDown", root.screenName)
    }

    Component {
        id: audioExpansion
        AudioPopup { screenName: root.screenName; embedded: true }
    }
}
