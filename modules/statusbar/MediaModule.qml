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
    readonly property string expansionSurface: "media"
    // Measure full metadata before creating the popup. Neither TextMetrics
    // depends on its assigned width, so screen limits cannot feed back into
    // the island's requested size. Include the panel and island insets.
    readonly property int expansionWidth: Math.ceil(Math.min(Metrics.mediaPanelMaximumWidth, Math.max(430,
        sourceMeasure.advanceWidth + Metrics.space8 + 2 * Metrics.space12,
        Metrics.space8 + 2 * Metrics.space12 + Metrics.mediaArtworkSize + Metrics.space12
        + Math.max(titleMeasure.advanceWidth, artistMeasure.advanceWidth,
            albumMeasure.advanceWidth, Metrics.mediaTransportWidth))))
    readonly property Component expansionComponent: mediaExpansion
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    TextMetrics {
        id: sourceMeasure
        text: MediaService.sourceName + (MediaService.sourcePageTitle ? " · " + MediaService.sourcePageTitle : "")
        font.family: Metrics.fontFamily
        font.pixelSize: Metrics.fontSmall
    }

    TextMetrics {
        id: titleMeasure
        text: MediaService.title
        font.family: Metrics.fontFamily
        font.pixelSize: Metrics.fontTitle
        font.weight: Font.Bold
    }

    TextMetrics {
        id: artistMeasure
        text: MediaService.artist
        font.family: Metrics.fontFamily
        font.pixelSize: Metrics.fontSmall
    }

    TextMetrics {
        id: albumMeasure
        text: MediaService.album
        font.family: Metrics.fontFamily
        font.pixelSize: Metrics.fontSmall
    }

    BarButton {
        id: button
        anchors.fill: parent
        icon: Icons.media
        foreground: MediaService.anyPlaying ? Theme.mauve : Theme.text
        compact: true
        active: SurfaceManager.isOpen("media", root.screenName)
        tooltip: Strings.media
        onClicked: ModuleActions.run("media", "primary", root.screenName)
        onRightClicked: ModuleActions.run("media", "secondary", root.screenName)
    }

    Component {
        id: mediaExpansion
        MediaPopup { screenName: root.screenName; embedded: true }
    }
}
