pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import qs.core

Singleton {
    id: root
    property bool shown: false
    property string screenName: ""
    property string kind: "volume"
    property real value: 0
    property bool muted: false
    property bool audioReady: false
    property bool sourceReady: false

    function show(nextKind, nextValue, isMuted) {
        root.kind = nextKind;
        root.value = Math.max(0, Math.min(1, nextValue));
        root.muted = isMuted;
        root.screenName = SurfaceManager.focusedScreenName();
        root.shown = true;
        hideDelay.restart();
    }
    function showVolume() {
        if (root.audioReady && AudioService.available)
            root.show("volume", AudioService.volume, AudioService.muted);
    }
    function showMicrophone() {
        if (root.sourceReady && AudioService.sourceAvailable)
            root.show("microphone", AudioService.sourceVolume, AudioService.sourceMuted);
    }
    Connections {
        target: AudioService
        function onVolumeChanged() { root.showVolume(); }
        function onMutedChanged() { root.showVolume(); }
        function onAvailableChanged() {
            root.audioReady = false;
            if (AudioService.available)
                Qt.callLater(() => { root.audioReady = AudioService.available; });
        }
        function onSourceVolumeChanged() { root.showMicrophone(); }
        function onSourceMutedChanged() { root.showMicrophone(); }
        function onSourceAvailableChanged() {
            root.sourceReady = false;
            if (AudioService.sourceAvailable)
                Qt.callLater(() => { root.sourceReady = AudioService.sourceAvailable; });
        }
    }
    Connections {
        target: BrightnessService
        function onPercentageChanged() {
            if (BrightnessService.available)
                root.show("brightness", BrightnessService.percentage / 100, false);
        }
    }
    Timer { id: hideDelay; interval: 1200; onTriggered: root.shown = false }
    IpcHandler {
        target: "osd"
        function status(): string {
            return JSON.stringify({shown: root.shown, kind: root.kind, value: root.value, muted: root.muted,
                screen: root.screenName, audioReady: root.audioReady,
                audioAvailable: AudioService.available, volume: AudioService.volume,
                sourceReady: root.sourceReady, sourceAvailable: AudioService.sourceAvailable,
                sourceVolume: AudioService.sourceVolume});
        }
    }
    Component.onCompleted: Qt.callLater(() => {
        root.audioReady = AudioService.available;
        root.sourceReady = AudioService.sourceAvailable;
    })
}
