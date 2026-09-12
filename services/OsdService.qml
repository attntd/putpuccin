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
    Connections {
        target: AudioService
        function onVolumeChanged() { root.showVolume(); }
        function onMutedChanged() { root.showVolume(); }
        function onAvailableChanged() {
            root.audioReady = false;
            if (AudioService.available)
                Qt.callLater(() => { root.audioReady = AudioService.available; });
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
            return JSON.stringify({shown: root.shown, kind: root.kind, value: root.value,
                screen: root.screenName, audioReady: root.audioReady,
                audioAvailable: AudioService.available, volume: AudioService.volume});
        }
    }
    Component.onCompleted: Qt.callLater(() => { root.audioReady = AudioService.available; })
}
