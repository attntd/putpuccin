pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.components
import qs.core
import qs.services

PopupFrame {
    id: root
    required property string screenName
    property int clockTick: 0
    readonly property var player: MediaService.activePlayer
    readonly property bool hasProgress: MediaService.hasTimeline
    readonly property string sourceDescription: MediaService.sourceName
        + (MediaService.sourcePageTitle ? " · " + MediaService.sourcePageTitle : "")
    readonly property string readingContext: root.player ? root.player.dbusName : ""

    component SourceToolTip: ToolTip {
        id: tooltip
        delay: Motion.textScrollPause
        contentItem: Text {
            text: tooltip.text
            textFormat: Text.PlainText
            color: Theme.text
            font.family: Metrics.fontFamily
            font.pixelSize: Metrics.fontSmall
            width: Math.min(implicitWidth, Metrics.popupWidth)
            wrapMode: Text.Wrap
        }
        background: Rectangle {
            color: Theme.withAlpha(Theme.base, Settings.surfaceOpacity)
            radius: Metrics.space4
            border.width: Metrics.borderWidth
            border.color: Theme.surface1
        }
    }

    function duration(seconds) {
        if (!Number.isFinite(seconds) || seconds < 0)
            return "0:00";
        const whole = Math.floor(seconds);
        const minutes = Math.floor(whole / 60);
        const secondsText = String(whole % 60).padStart(2, "0");
        return minutes < 60 ? minutes + ":" + secondsText
            : Math.floor(minutes / 60) + ":" + String(minutes % 60).padStart(2, "0") + ":" + secondsText;
    }

    Timer {
        objectName: "mediaPositionTimer"
        interval: 1000
        running: root.visible && MediaService.playing && root.hasProgress
        repeat: true
        onTriggered: root.clockTick++
    }

    ColumnLayout {
        width: parent.width
        spacing: Metrics.space12

        ScrollingText {
            objectName: "mediaSource"
            visible: root.player !== null && root.sourceDescription.length > 0
            text: root.sourceDescription
            contextKey: root.readingContext
            color: Theme.subtext0
            font.family: Metrics.fontFamily
            font.pixelSize: Metrics.fontSmall
            horizontalAlignment: Qt.AlignHCenter
            Layout.fillWidth: true
            Layout.minimumWidth: 0
        }

        RowLayout {
            visible: MediaService.players.length > 1
            Layout.fillWidth: true
            Item { Layout.fillWidth: true }
            ComboBox {
                id: playerSelector
                objectName: "mediaPlayerSelector"
                visible: MediaService.players.length > 1
                model: [null].concat(MediaService.players)
                implicitWidth: 150
                currentIndex: MediaService.selectedPlayer
                    ? MediaService.players.indexOf(MediaService.selectedPlayer) + 1 : 0
                displayText: MediaService.playerLabel(MediaService.selectedPlayer)
                onActivated: index => MediaService.selectPlayer(index === 0 ? null : MediaService.players[index - 1])
                contentItem: Text {
                    text: playerSelector.displayText
                    textFormat: Text.PlainText
                    color: Theme.text
                    font.family: Metrics.fontFamily
                    font.pixelSize: Metrics.fontSmall
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                    leftPadding: Metrics.space8
                }
                SourceToolTip {
                    objectName: "mediaSelectorTooltip"
                    parent: playerSelector
                    text: playerSelector.displayText
                    visible: (playerSelector.hovered || playerSelector.activeFocus)
                        && playerSelector.contentItem.truncated
                }
                background: Rectangle {
                    color: Theme.controlBackground(Theme.text, playerSelector.hovered, playerSelector.down)
                    radius: 8
                    border.width: Metrics.borderWidth
                    border.color: playerSelector.activeFocus ? Theme.accent : Theme.surface1
                }
                delegate: ItemDelegate {
                    id: playerOption
                    required property var modelData
                    required property int index
                    width: playerSelector.width
                    text: MediaService.playerLabel(modelData)
                    highlighted: playerSelector.highlightedIndex === index
                    contentItem: Text {
                        text: playerOption.text
                        textFormat: Text.PlainText
                        color: Theme.text
                        font.family: Metrics.fontFamily
                        font.pixelSize: Metrics.fontSmall
                        elide: Text.ElideRight
                    }
                    SourceToolTip {
                        objectName: "mediaOptionTooltip"
                        parent: playerOption
                        text: playerOption.text
                        visible: (playerOption.hovered || playerOption.activeFocus)
                            && playerOption.contentItem.truncated
                    }
                    background: Rectangle {
                        radius: Metrics.space4
                        color: Theme.controlBackground(Theme.accent, playerOption.hovered,
                            playerOption.down, playerOption.highlighted)
                    }
                }
                popup: Popup {
                    y: playerSelector.height
                    width: playerSelector.width
                    padding: Metrics.space4
                    implicitHeight: contentItem.implicitHeight + topPadding + bottomPadding
                    background: Rectangle {
                        color: Theme.withAlpha(Theme.base, Settings.surfaceOpacity)
                        radius: Metrics.space8
                        border.width: Metrics.borderWidth
                        border.color: Theme.surface1
                    }
                    contentItem: ListView {
                        implicitHeight: Math.min(contentHeight, 240)
                        clip: true
                        model: playerSelector.popup.visible ? playerSelector.delegateModel : null
                        currentIndex: playerSelector.highlightedIndex
                    }
                }
            }
        }

        RowLayout {
            visible: root.player !== null
            spacing: Metrics.space12
            Layout.fillWidth: true

            Rectangle {
                Layout.preferredWidth: Metrics.mediaArtworkSize
                Layout.minimumWidth: Metrics.mediaArtworkSize
                Layout.preferredHeight: Metrics.mediaArtworkSize
                radius: 12
                color: Theme.controlBackground(Theme.surface0)
                clip: true

                Image {
                    id: artwork
                    objectName: "mediaArtwork"
                    anchors.fill: parent
                    source: MediaService.artUrl
                    sourceSize.width: 2 * Metrics.mediaArtworkSize
                    sourceSize.height: 2 * Metrics.mediaArtworkSize
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    visible: status === Image.Ready
                }
                Text {
                    objectName: "mediaArtworkFallback"
                    visible: artwork.status !== Image.Ready
                    anchors.centerIn: parent
                    text: Icons.media
                    color: Theme.overlay1
                    font.family: Metrics.fontFamily
                    font.pixelSize: 32
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Metrics.space6
                ScrollingText {
                    objectName: "mediaTitle"
                    text: MediaService.title
                    contextKey: root.readingContext
                    color: Theme.text
                    font.family: Metrics.fontFamily
                    font.pixelSize: Metrics.fontTitle
                    font.weight: Font.Bold
                    Layout.fillWidth: true
                    Layout.minimumWidth: 0
                }
                ScrollingText {
                    objectName: "mediaAlbum"
                    visible: MediaService.album.length > 0
                    text: MediaService.album
                    contextKey: root.readingContext
                    color: Theme.subtext0
                    font.family: Metrics.fontFamily
                    font.pixelSize: Metrics.fontSmall
                    Layout.fillWidth: true
                    Layout.minimumWidth: 0
                }
                ScrollingText {
                    objectName: "mediaArtist"
                    text: MediaService.artist
                    contextKey: root.readingContext
                    color: Theme.subtext0
                    font.family: Metrics.fontFamily
                    font.pixelSize: Metrics.fontSmall
                    Layout.fillWidth: true
                    Layout.minimumWidth: 0
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Metrics.space6
                    Item { Layout.fillWidth: true }
                    ActionButton {
                        objectName: "mediaPrevious"
                        text: ""; glyph: Icons.previous; implicitWidth: Metrics.mediaTransportButtonWidth
                        Accessible.name: Strings.mediaPrevious
                        ToolTip.visible: hovered
                        ToolTip.text: Strings.mediaPrevious
                        enabled: root.player && root.player.canGoPrevious
                        onClicked: root.player.previous()
                    }
                    ActionButton {
                        objectName: "mediaPlayPause"
                        text: ""; glyph: MediaService.playing ? Icons.pause : Icons.play
                        Accessible.name: MediaService.playing ? Strings.mediaPause : Strings.mediaPlay
                        ToolTip.visible: hovered
                        ToolTip.text: Accessible.name
                        accent: true; implicitWidth: Metrics.mediaTransportPrimaryWidth
                        enabled: root.player && root.player.canTogglePlaying
                        onClicked: root.player.togglePlaying()
                    }
                    ActionButton {
                        objectName: "mediaNext"
                        text: ""; glyph: Icons.next; implicitWidth: Metrics.mediaTransportButtonWidth
                        Accessible.name: Strings.mediaNext
                        ToolTip.visible: hovered
                        ToolTip.text: Strings.mediaNext
                        enabled: root.player && root.player.canGoNext
                        onClicked: root.player.next()
                    }
                    Item { Layout.fillWidth: true }
                }
            }
        }

        ColumnLayout {
            visible: root.hasProgress
            Layout.fillWidth: true
            spacing: Metrics.space4

            StatusSlider {
                id: progress
                objectName: "mediaProgress"
                Accessible.name: Strings.media
                from: 0
                to: Math.max(1, MediaService.timelineDuration)
                value: {
                    root.clockTick;
                    return root.player ? Math.max(0, Math.min(to, root.player.position)) : 0;
                }
                enabled: MediaService.canSeekTimeline
                Layout.fillWidth: true
                onMoved: {
                    MediaService.seekTimeline(value);
                }
            }
            RowLayout {
                Layout.fillWidth: true
                Text {
                    text: root.duration(progress.value)
                    color: Theme.subtext0
                    font.family: Metrics.fontFamily
                    font.pixelSize: 10
                }
                Item { Layout.fillWidth: true }
                Text {
                    text: root.duration(progress.to)
                    color: Theme.subtext0
                    font.family: Metrics.fontFamily
                    font.pixelSize: 10
                }
            }
        }

        EmptyState {
            visible: root.player === null
            Layout.fillWidth: true
            Layout.preferredHeight: implicitHeight
            icon: Icons.media
            title: Strings.nothingPlaying
        }
    }
}
