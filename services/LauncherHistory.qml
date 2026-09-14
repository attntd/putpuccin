pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.core
import qs.services

Singleton {
    id: root

    readonly property string path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state")
        + "/quickshell-de/launcher.json"
    readonly property var entries: state.records
    readonly property bool ready: state.ready
    readonly property string errorMessage: state.errorMessage
    readonly property int maximumEntries: 100

    function valid(record, persistent) {
        if (!record) return false;
        if (record.kind === "application") return typeof record.id === "string" && record.id.length > 0;
        if (record.kind === "file") return typeof record.id === "string" && record.id.startsWith("/");
        if (record.kind === "command") return !persistent && typeof record.id === "string" && record.id.trim().length > 0;
        return !persistent && record.kind === "clipboard" && Number.isSafeInteger(record.id) && record.id >= 0;
    }

    function unique(records) {
        const seen = new Set();
        return records.filter(record => {
            const key = record.kind + ":" + record.id;
            if (seen.has(key)) return false;
            seen.add(key);
            return true;
        }).slice(0, maximumEntries);
    }

    function record(kind, id) {
        const entry = { kind: kind, id: id };
        if (!valid(entry, false)) return;
        state.records = unique([entry].concat(state.records));
        state.dirty = true;
        if (state.writable) saveDelay.restart();
    }

    function copyClipboard(id) {
        if (ClipboardService.pendingOperation.length > 0) return false;
        state.pendingClipboardId = id;
        ClipboardService.copy(id);
        return true;
    }

    function finish(records) {
        if (state.ready) return;
        // An action can arrive before the initial asynchronous disk read finishes.
        state.records = unique(state.records.concat(records.filter(entry => valid(entry, true))));
        state.ready = true;
        if (state.dirty && state.writable) saveDelay.restart();
    }

    function flush() {
        if (!state.writable || !state.ready || !state.dirty) return;
        state.dirty = false;
        file.setText(JSON.stringify({ schemaVersion: 1,
            records: state.records.filter(entry => valid(entry, true)) }));
    }

    QtObject {
        id: state
        property var records: []
        property bool ready: false
        property bool writable: false
        property bool dirty: false
        property int pendingClipboardId: -1
        property string errorMessage: ""
    }

    Connections {
        target: ClipboardService
        function onCopied(entryId) {
            if (entryId === state.pendingClipboardId) root.record("clipboard", entryId);
            state.pendingClipboardId = -1;
        }
        function onEntriesChanged() {
            // Clipboard IDs must never outlive their original entries or be saved to disk.
            const ids = new Set(ClipboardService.entries.map(entry => entry.id));
            state.records = state.records.filter(entry => entry.kind !== "clipboard" || ids.has(entry.id));
        }
        function onErrorMessageChanged() {
            if (ClipboardService.errorMessage) state.pendingClipboardId = -1;
        }
    }

    // FileView cannot create private directories or quarantine corrupt JSON.
    // One startup helper, 3 s deadline, no polling; failure keeps session history usable.
    Process {
        id: initialize
        command: ["python3", Quickshell.shellPath("scripts/launcher-state"), root.path]
        running: true
        onExited: code => {
            deadline.stop();
            if (code === 0) {
                state.writable = true;
                file.path = root.path;
            } else {
                state.errorMessage = Strings.launcherHistoryUnavailable;
                root.finish([]);
            }
        }
    }
    Timer {
        id: deadline
        interval: 3000
        running: true
        onTriggered: {
            initialize.running = false;
            state.errorMessage = Strings.launcherHistoryUnavailable;
            root.finish([]);
        }
    }
    FileView {
        id: file
        printErrors: false
        watchChanges: false
        atomicWrites: true
        onLoaded: {
            try {
                const data = JSON.parse(text());
                if (data.schemaVersion !== 1 || !Array.isArray(data.records)) throw new Error("Invalid history");
                root.finish(data.records);
            } catch (error) {
                state.writable = false;
                state.errorMessage = Strings.launcherHistoryUnavailable;
                root.finish([]);
            }
        }
        onLoadFailed: {
            state.writable = false;
            state.errorMessage = Strings.launcherHistoryUnavailable;
            root.finish([]);
        }
        onSaveFailed: {
            state.dirty = true;
            state.errorMessage = Strings.launcherHistoryUnavailable;
        }
    }
    Timer { id: saveDelay; interval: 250; onTriggered: root.flush() }
    Component.onDestruction: {
        initialize.running = false;
        root.flush();
        file.waitForJob();
    }
}
