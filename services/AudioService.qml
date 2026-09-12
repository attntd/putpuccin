pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Services.Pipewire

Singleton {
    id: root

    readonly property string state: !Pipewire.ready ? "loading" : (sink && sink.audio ? "ready" : "unavailable")
    readonly property var sink: Pipewire.defaultAudioSink
    readonly property bool available: state === "ready"
    readonly property bool muted: available ? sink.audio.muted : false
    readonly property real volume: available ? sink.audio.volume : 0
    readonly property string description: sink ? (sink.description || sink.nickname || sink.name) : ""
    readonly property string sourceState: !Pipewire.ready ? "loading" : (source && source.audio ? "ready" : "unavailable")
    readonly property var source: Pipewire.defaultAudioSource
    readonly property bool sourceAvailable: sourceState === "ready"
    readonly property bool sourceMuted: sourceAvailable ? source.audio.muted : false
    readonly property real sourceVolume: sourceAvailable ? source.audio.volume : 0
    readonly property var sinks: {
        const values = Pipewire.nodes ? Pipewire.nodes.values : [];
        return values.filter(node => node && node.audio && node.isSink && !node.isStream);
    }
    readonly property var sources: {
        const values = Pipewire.nodes ? Pipewire.nodes.values : [];
        return values.filter(node => node && node.audio && !node.isSink && !node.isStream);
    }
    property string errorMessage: ""

    PwObjectTracker {
        objects: root.sink ? [root.sink] : []
    }

    PwObjectTracker {
        objects: root.sinks
    }

    PwObjectTracker {
        objects: root.source ? [root.source] : []
    }

    PwObjectTracker {
        objects: root.sources
    }

    function setVolume(value) {
        if (!root.available)
            return;
        root.sink.audio.volume = Math.max(0, Math.min(1, value));
    }

    function adjustVolume(delta) {
        root.setVolume(root.volume + delta);
    }

    function toggleMute() {
        if (root.available)
            root.sink.audio.muted = !root.sink.audio.muted;
    }

    function selectSink(node) {
        if (node && node.audio && node.isSink)
            Pipewire.preferredDefaultAudioSink = node;
    }

    function setSourceVolume(value) {
        if (!root.sourceAvailable)
            return;
        root.source.audio.volume = Math.max(0, Math.min(1, value));
    }

    function toggleSourceMute() {
        if (root.sourceAvailable)
            root.source.audio.muted = !root.source.audio.muted;
    }

    function selectSource(node) {
        if (node && node.audio && !node.isSink)
            Pipewire.preferredDefaultAudioSource = node;
    }
}
