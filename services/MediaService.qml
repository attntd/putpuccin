pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import qs.core

Singleton {
    id: root

    // MPRIS exposes audio and video alike. A stopped player is still available;
    // only removal from the native model means it has disconnected.
    readonly property var rawPlayers: Mpris.players.values
    readonly property var players: rawPlayers.filter(player =>
        player === selection.explicitPlayer || !isDuplicateBrowserPlayer(player))
    readonly property var selectedPlayer: selection.explicitPlayer
    readonly property var activePlayer: {
        if (root.players.indexOf(selection.explicitPlayer) >= 0)
            return selection.explicitPlayer;
        const recent = root.players.indexOf(selection.lastPlayingPlayer) >= 0
            ? selection.lastPlayingPlayer : null;
        if (recent && recent.playbackState === MprisPlaybackState.Playing)
            return recent;
        for (const player of root.players) {
            if (player.playbackState === MprisPlaybackState.Playing)
                return player;
        }
        if (recent)
            return recent;
        for (const player of root.players) {
            if (player.playbackState === MprisPlaybackState.Paused)
                return player;
        }
        return root.players.length > 0 ? root.players[0] : null;
    }
    readonly property bool visible: activePlayer !== null
    readonly property bool playing: !!activePlayer
        && activePlayer.playbackState === MprisPlaybackState.Playing
    readonly property bool anyPlaying: rawPlayers.some(player =>
        player.playbackState === MprisPlaybackState.Playing)
    readonly property string title: activePlayer ? (activePlayer.trackTitle || Strings.unknownMedia) : ""
    readonly property string artist: activePlayer ? (activePlayer.trackArtist || activePlayer.identity || "") : ""
    readonly property string album: activePlayer ? activePlayer.trackAlbum : ""
    readonly property string artUrl: activePlayer ? activePlayer.trackArtUrl : ""
    readonly property string sourceName: {
        if (!activePlayer)
            return "";
        const entry = activePlayer.desktopEntry
            ? DesktopEntries.byId(activePlayer.desktopEntry) : null;
        return entry && entry.name ? entry.name : (activePlayer.identity || Strings.player);
    }
    // Our browser bridge supplies this from the same tab as the media. Standard
    // MPRIS has no page-title field; never substitute the focused window/title.
    readonly property string sourcePageTitle: activePlayer
        && activePlayer.dbusName.startsWith("org.mpris.MediaPlayer2.quickshell_browser.")
        ? String(activePlayer.metadata["browser:pageTitle"] || "") : ""

    readonly property bool nativeDurationValid: !!activePlayer && activePlayer.lengthSupported
        && Number.isFinite(activePlayer.length) && activePlayer.length > 0
    readonly property bool timelineDurationPending: durationGrace.running
        && durationCache.key !== "" && durationCache.key === timelineKey()
    readonly property real timelineDuration: nativeDurationValid && activePlayer ? activePlayer.length
        : timelineDurationPending ? durationCache.seconds : -1
    readonly property bool hasTimeline: !!activePlayer && activePlayer.positionSupported
        && timelineDuration > 0
    readonly property bool canSeekTimeline: !!activePlayer && hasTimeline && activePlayer.canSeek

    // Some sources remove length between two metadata updates. Keep only the
    // last known duration of this exact track, briefly; never invent a range
    // for a live stream or carry it over to a different track/player.
    QtObject {
        id: durationCache
        property string key: ""
        property real seconds: -1
        property bool missing: false
    }

    function isBrowserBridge(player) {
        return !!player && player.dbusName.startsWith("org.mpris.MediaPlayer2.quickshell_browser.");
    }
    function playerLabel(player) {
        if (!player)
            return Strings.mediaAutomatic;
        const name = player.identity || Strings.player;
        const pageTitle = isBrowserBridge(player) ? String(player.metadata["browser:pageTitle"] || "") : "";
        return pageTitle ? name + " · " + pageTitle : name;
    }
    function browserHost(player) {
        if (isBrowserBridge(player))
            return String(player.metadata["browser:sourceHost"] || "").replace(/^www\./, "");
        const entry = String(player.desktopEntry || "").replace(/\.desktop$/, "").toLowerCase();
        if (["zen", "zen-browser", "zen-browser-bin"].indexOf(entry) < 0)
            return "";
        // Only compare the origin. Do not copy query strings into adapter state.
        const match = String(player.metadata["xesam:url"] || "")
            .match(/^https:\/\/(?:www\.)?(soundcloud\.com|music\.apple\.com)(?::443)?(?:[\/?#]|$)/i);
        return match ? match[1].toLowerCase() : "";
    }
    function sameBrowserMedia(nativePlayer, bridge) {
        const host = browserHost(nativePlayer);
        return host !== "" && host === browserHost(bridge)
            && nativePlayer.playbackState === bridge.playbackState
            && nativePlayer.trackTitle !== "" && nativePlayer.trackTitle === bridge.trackTitle
            && nativePlayer.trackArtist === bridge.trackArtist
            && nativePlayer.trackAlbum === bridge.trackAlbum;
    }
    function isDuplicateBrowserPlayer(player) {
        if (isBrowserBridge(player) || !browserHost(player))
            return false;
        const matches = rawPlayers.filter(other => isBrowserBridge(other) && sameBrowserMedia(player, other));
        if (matches.length !== 1)
            return false;
        // Ambiguous identical tabs stay independently selectable. A manual
        // native selection is also kept, even if a richer bridge appears.
        return rawPlayers.filter(other => !isBrowserBridge(other) && sameBrowserMedia(other, matches[0])).length === 1;
    }
    Timer {
        id: durationGrace
        interval: 1500
        repeat: false
    }
    function timelineKey() {
        if (!activePlayer)
            return "";
        const trackId = String(activePlayer.metadata["mpris:trackid"] || "");
        if (!trackId || trackId === "/org/mpris/MediaPlayer2/TrackList/NoTrack")
            return "";
        // Gecko uses a fixed track path. Native uniqueId also tracks title/URL
        // changes; artist/album disambiguate equal titles without an ID change.
        return JSON.stringify([activePlayer.dbusName, activePlayer.uniqueId, trackId,
            activePlayer.trackTitle, activePlayer.trackArtist, activePlayer.trackAlbum]);
    }
    function refreshDuration() {
        const key = timelineKey();
        if (key !== durationCache.key) {
            durationGrace.stop();
            durationCache.key = key;
            durationCache.seconds = -1;
            durationCache.missing = false;
        }
        if (activePlayer && activePlayer.lengthSupported
                && Number.isFinite(activePlayer.length) && activePlayer.length > 0) {
            durationGrace.stop();
            durationCache.seconds = activePlayer.length;
            durationCache.missing = false;
        } else if (!activePlayer || activePlayer.lengthSupported || !key) {
            // Explicit zero/invalid length is not a transient missing key.
            durationGrace.stop();
            durationCache.seconds = -1;
            durationCache.missing = true;
        } else if (!durationCache.missing) {
            durationCache.missing = true;
            if (durationCache.seconds > 0)
                durationGrace.start();
        }
    }
    function seekTimeline(seconds) {
        if (canSeekTimeline && Number.isFinite(seconds))
            activePlayer.position = Math.max(0, Math.min(timelineDuration, seconds));
    }
    onActivePlayerChanged: refreshDuration()
    Connections {
        target: root.activePlayer
        function onMetadataChanged() { root.refreshDuration(); }
        function onPostTrackChanged() { root.refreshDuration(); }
        function onLengthChanged() { root.refreshDuration(); }
        function onLengthSupportedChanged() { root.refreshDuration(); }
    }

    QtObject {
        id: selection
        property var explicitPlayer: null
        property var lastPlayingPlayer: null
    }

    function selectPlayer(player) {
        if (player === null || root.players.indexOf(player) >= 0)
            selection.explicitPlayer = player;
    }

    onRawPlayersChanged: {
        if (root.rawPlayers.indexOf(selection.explicitPlayer) < 0)
            selection.explicitPlayer = null;
        if (root.rawPlayers.indexOf(selection.lastPlayingPlayer) < 0)
            selection.lastPlayingPlayer = null;
    }

    Instantiator {
        model: Mpris.players
        delegate: Connections {
            required property var modelData
            target: modelData
            function rememberPlaying() {
                // Use the player that emitted the event, not the first playing
                // entry. Delayed metadata from another tab must not steal it.
                if (modelData.playbackState === MprisPlaybackState.Playing)
                    selection.lastPlayingPlayer = modelData;
            }
            function onPlaybackStateChanged() { rememberPlaying(); }
            Component.onCompleted: rememberPlaying()
        }
    }

    IpcHandler {
        target: "media"
        // A privacy-preserving diagnostic: never export titles or stream URLs.
        function status(): string {
            return JSON.stringify({
                playerCount: root.players.length,
                rawPlayerCount: root.rawPlayers.length,
                hasActivePlayer: root.activePlayer !== null,
                manualSelection: root.selectedPlayer !== null,
                activePlaying: root.playing,
                anyPlaying: root.anyPlaying,
                hasTimeline: root.hasTimeline,
                timelineDuration: root.timelineDuration,
                timelineDurationPending: root.timelineDurationPending,
                playbackStates: root.players.map(player =>
                    MprisPlaybackState.toString(player.playbackState)),
                timeline: root.players.map(player => ({
                    positionSupported: player.positionSupported,
                    lengthSupported: player.lengthSupported,
                    position: player.positionSupported ? player.position : null,
                    length: player.lengthSupported ? player.length : null,
                    canSeek: player.canSeek
                }))
            });
        }
    }
}
