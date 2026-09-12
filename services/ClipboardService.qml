pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.core
import qs.services

Singleton {
    id: root

    readonly property string runtimeRoot: {
        const runtime = Quickshell.env("XDG_RUNTIME_DIR");
        return runtime && runtime.length > 0 ? runtime : "/tmp";
    }
    readonly property string databasePath: runtimeRoot + "/quickshell-de-cliphist-" + Quickshell.processId + ".db"
    readonly property string thumbnailRoot: runtimeRoot + "/quickshell-de-clipboard-thumbs-" + Quickshell.processId
    readonly property var processEnvironment: ({
        "CLIPHIST_DB_PATH": root.databasePath,
        "CLIPHIST_MAX_ITEMS": String(Settings.clipboardMaxItems),
        "QS_CLIP_MAX_BYTES": String(Settings.clipboardMaxBytes),
        "QS_CLIP_THUMB_DIR": root.thumbnailRoot
    })

    property string state: "loading"
    property bool paused: false
    property var entries: []
    property string query: ""
    property string errorMessage: ""
    property string previousToplevelAddress: ""
    property int watcherFailures: 0
    property string pendingOperation: ""
    property var thumbnailQueue: []
    property int activeThumbnailId: -1
    property int mutationRevision: 0
    property int listRevision: 0
    property int thumbnailRevision: 0
    property bool listPending: false
    property bool refreshQueued: false
    property bool cleanupPending: false
    property bool cleanupRunning: false
    property bool textWatcherDesired: true
    property bool imageWatcherDesired: true
    property bool textWatcherRestarting: false
    property bool imageWatcherRestarting: false

    readonly property bool available: state === "ready"
    readonly property var filteredEntries: {
        const needle = root.query.trim().toLocaleLowerCase();
        if (!needle)
            return root.entries;
        return root.entries.filter(entry => entry.preview.toLocaleLowerCase().indexOf(needle) >= 0);
    }

    signal copied(int entryId)
    signal deleted(int entryId)
    signal wiped()

    function rememberFocus() {
        root.previousToplevelAddress = Hyprland.activeToplevel ? Hyprland.activeToplevel.address : "";
    }

    function parseList(text) {
        const next = [];
        for (const line of text.split("\n")) {
            if (!line)
                continue;
            const tab = line.indexOf("\t");
            if (tab <= 0)
                continue;
            const id = Number(line.slice(0, tab));
            if (!Number.isSafeInteger(id) || id < 0)
                continue;
            const preview = line.slice(tab + 1);
            const previous = root.entries.find(entry => entry.id === id && entry.raw === line);
            next.push({
                "id": id,
                "raw": line,
                "preview": preview,
                "binary": preview.indexOf("[[ binary data") === 0,
                "thumbnail": previous ? previous.thumbnail : ""
            });
            if (next.length >= Settings.clipboardMaxItems)
                break;
        }
        root.entries = next;
        root.thumbnailQueue = root.thumbnailQueue.filter(id => next.some(entry => entry.id === id));
        root.scheduleThumbnailCleanup();
        root.state = "ready";
        root.errorMessage = "";
    }

    function refresh() {
        if (listProcess.running || root.listPending || actionProcess.running) {
            root.refreshQueued = true;
            return;
        }
        root.refreshQueued = false;
        root.listRevision = root.mutationRevision;
        root.listPending = true;
        listProcess.running = true;
    }

    function setPaused(value) {
        root.paused = value;
        if (!value) {
            root.watcherFailures = 0;
            root.textWatcherDesired = true;
            root.imageWatcherDesired = true;
        }
    }

    function copy(entryId) {
        if (!Number.isSafeInteger(entryId) || entryId < 0 || root.pendingOperation.length > 0 || actionProcess.running)
            return;
        root.pendingOperation = "copy:" + entryId;
        actionProcess.exec({
            command: [Quickshell.shellPath("scripts/clipboard-action"), "copy", String(entryId)],
            environment: root.processEnvironment
        });
    }

    function remove(entryId) {
        if (!Number.isSafeInteger(entryId) || entryId < 0 || root.pendingOperation.length > 0 || actionProcess.running)
            return;
        root.mutationRevision++;
        root.thumbnailQueue = root.thumbnailQueue.filter(id => id !== entryId);
        root.pendingOperation = "delete:" + entryId;
        actionProcess.exec({
            command: [Quickshell.shellPath("scripts/clipboard-action"), "delete", String(entryId)],
            environment: root.processEnvironment
        });
    }

    function wipe() {
        if (root.pendingOperation.length > 0 || actionProcess.running)
            return;
        root.mutationRevision++;
        root.thumbnailQueue = [];
        root.pendingOperation = "wipe";
        actionProcess.exec({
            command: [Quickshell.shellPath("scripts/clipboard-action"), "wipe"],
            environment: root.processEnvironment
        });
    }

    function requestThumbnail(entryId) {
        if (!Number.isInteger(entryId) || root.activeThumbnailId === entryId
                || root.thumbnailQueue.indexOf(entryId) >= 0)
            return;
        const entry = root.entries.find(item => item.id === entryId);
        if (!entry || entry.thumbnail.length > 0)
            return;
        root.thumbnailQueue = root.thumbnailQueue.concat([entryId]);
        root.startNextThumbnail();
    }

    function startNextThumbnail() {
        if (thumbnailProcess.running || cleanupProcess.running || root.cleanupRunning
                || actionProcess.running || root.pendingOperation.length > 0 || listProcess.running)
            return;
        if (root.cleanupPending) {
            root.cleanupPending = false;
            root.cleanupRunning = true;
            cleanupProcess.exec({
                command: [Quickshell.shellPath("scripts/clipboard-action"), "prune",
                    root.entries.map(entry => entry.id).join(",")],
                environment: root.processEnvironment
            });
            return;
        }
        root.thumbnailQueue = root.thumbnailQueue.filter(id => root.entries.some(entry => entry.id === id));
        if (root.thumbnailQueue.length === 0)
            return;
        const nextQueue = root.thumbnailQueue.slice();
        root.activeThumbnailId = nextQueue.shift();
        root.thumbnailQueue = nextQueue;
        root.thumbnailRevision = root.mutationRevision;
        thumbnailProcess.exec({
            command: [Quickshell.shellPath("scripts/clipboard-action"), "thumbnail", String(root.activeThumbnailId)],
            environment: root.processEnvironment
        });
    }

    function restartWatchers() {
        if (root.paused)
            return;
        root.textWatcherDesired = true;
        root.imageWatcherDesired = true;
    }

    function restartWatchersForSettings() {
        if (root.paused)
            return;
        root.textWatcherRestarting = textWatcher.running;
        root.imageWatcherRestarting = imageWatcher.running;
        root.textWatcherDesired = false;
        root.imageWatcherDesired = false;
        settingsRestart.restart();
    }

    Process {
        id: textWatcher
        running: root.textWatcherDesired && !root.paused
        command: ["wl-paste", "--type", "text", "--watch", Quickshell.shellPath("scripts/clipboard-store")]
        environment: root.processEnvironment
        stdout: SplitParser {
            onRead: data => {
                root.watcherFailures = 0;
                root.refresh();
            }
        }
        stderr: StdioCollector {
            id: textWatcherError
        }
        onExited: exitCode => {
            if (root.paused || root.textWatcherRestarting)
                return;
            root.textWatcherDesired = false;
            root.state = "unavailable";
            root.errorMessage = textWatcherError.text.trim() || "Listener tekstu schowka zatrzymał się.";
            root.watcherFailures++;
            watcherRestart.restart();
        }
    }

    Process {
        id: imageWatcher
        running: root.imageWatcherDesired && !root.paused
        command: ["wl-paste", "--type", "image", "--watch", Quickshell.shellPath("scripts/clipboard-store")]
        environment: root.processEnvironment
        stdout: SplitParser {
            onRead: data => {
                root.watcherFailures = 0;
                root.refresh();
            }
        }
        stderr: StdioCollector {
            id: imageWatcherError
        }
        onExited: exitCode => {
            if (root.paused || root.imageWatcherRestarting)
                return;
            root.imageWatcherDesired = false;
            root.state = "unavailable";
            root.errorMessage = imageWatcherError.text.trim() || "Listener obrazów schowka zatrzymał się.";
            root.watcherFailures++;
            watcherRestart.restart();
        }
    }

    Timer {
        id: watcherRestart
        interval: Math.min(30000, 1000 * Math.pow(2, Math.max(0, root.watcherFailures - 1)))
        onTriggered: root.restartWatchers()
    }

    Timer {
        id: settingsRestart
        interval: 20
        repeat: true
        onTriggered: {
            if (textWatcher.running || imageWatcher.running)
                return;
            stop();
            root.textWatcherRestarting = false;
            root.imageWatcherRestarting = false;
            root.watcherFailures = 0;
            root.restartWatchers();
        }
    }

    function scheduleThumbnailCleanup() {
        root.cleanupPending = true;
        Qt.callLater(root.startNextThumbnail);
    }

    function finishList(exitCode) {
        if (!root.listPending)
            return;
        root.listPending = false;
        if (root.listRevision !== root.mutationRevision) {
            root.refreshQueued = true;
        } else if (exitCode === 0) {
            root.parseList(listOutput.text);
        } else {
            root.state = "unavailable";
            root.errorMessage = listError.text.trim() || "Nie można odczytać historii schowka.";
        }
        if (root.refreshQueued)
            Qt.callLater(root.refresh);
        Qt.callLater(root.startNextThumbnail);
    }

    function finishAction(exitCode) {
        const operation = root.pendingOperation;
        if (!operation)
            return;
        root.pendingOperation = "";
        if (exitCode !== 0) {
            root.errorMessage = actionError.text.trim() || "Operacja na schowku nie powiodła się.";
        } else if (operation.indexOf("copy:") === 0) {
            root.copied(Number(operation.slice(5)));
            if (Settings.clipboardAutoPaste && root.previousToplevelAddress)
                pasteDelay.restart();
        } else if (operation.indexOf("delete:") === 0) {
            const id = Number(operation.slice(7));
            root.entries = root.entries.filter(entry => entry.id !== id);
            root.deleted(id);
            root.refreshQueued = true;
        } else if (operation === "wipe") {
            root.entries = [];
            root.wiped();
            root.refreshQueued = true;
        }
        root.scheduleThumbnailCleanup();
        if (root.refreshQueued)
            Qt.callLater(root.refresh);
    }

    Process {
        id: listProcess
        command: ["timeout", "--kill-after=1s", "5s", "cliphist", "list"]
        environment: root.processEnvironment
        stdout: StdioCollector { id: listOutput }
        stderr: StdioCollector { id: listError }
        onExited: exitCode => root.finishList(exitCode)
        // FailedToStart does not emit exited in Quickshell 0.3.1.
        onRunningChanged: if (!running) Qt.callLater(() => {
            if (!listProcess.running && root.listPending)
                root.finishList(-1);
        })
    }

    Process {
        id: actionProcess
        stderr: StdioCollector { id: actionError }
        onExited: exitCode => root.finishAction(exitCode)
        onRunningChanged: if (!running) Qt.callLater(() => {
            if (!actionProcess.running && root.pendingOperation.length > 0)
                root.finishAction(-1);
        })
    }

    Timer {
        id: pasteDelay
        interval: Settings.reducedMotion ? 0 : Motion.fast
        onTriggered: HyprlandService.requestPaste(root.previousToplevelAddress)
    }

    function finishThumbnail(exitCode) {
        const activeId = root.activeThumbnailId;
        if (activeId < 0)
            return;
        root.activeThumbnailId = -1;
        let accepted = false;
        if (exitCode === 0 && root.thumbnailRevision === root.mutationRevision) {
            const parts = thumbnailOutput.text.trim().split("\t");
            const expectedPath = root.thumbnailRoot + "/" + activeId;
            if (parts.length === 2 && Number(parts[0]) === activeId && parts[1] === expectedPath) {
                accepted = root.entries.some(entry => entry.id === activeId);
                root.entries = root.entries.map(entry => entry.id === activeId
                    ? Object.assign({}, entry, { "thumbnail": "file://" + expectedPath }) : entry);
            }
        }
        // Serialized after thumbnail completion, so a late decode cannot
        // recreate a deleted/wiped/evicted preview after this reconciliation.
        if (accepted)
            Qt.callLater(root.startNextThumbnail);
        else
            root.scheduleThumbnailCleanup();
    }

    Process {
        id: thumbnailProcess
        stdout: StdioCollector { id: thumbnailOutput }
        onExited: exitCode => root.finishThumbnail(exitCode)
        onRunningChanged: if (!running) Qt.callLater(() => {
            if (!thumbnailProcess.running && root.activeThumbnailId >= 0)
                root.finishThumbnail(-1);
        })
    }

    Process {
        id: cleanupProcess
        onRunningChanged: if (!running) Qt.callLater(() => {
            if (!cleanupProcess.running && root.cleanupRunning) {
                root.cleanupRunning = false;
                root.startNextThumbnail();
            }
        })
    }

    IpcHandler {
        target: "clipboard"

        function setPaused(paused: bool): void {
            root.setPaused(paused);
        }

        function paused(): bool {
            return root.paused;
        }

        function clear(): void {
            // IPC intentionally cannot bypass the confirmation UI.
            root.errorMessage = "Czyszczenie wymaga potwierdzenia w interfejsie.";
        }
    }

    Connections {
        target: SurfaceManager
        function onChanged(screenName, surfaceId) {
            if (surfaceId === "clipboard")
                root.rememberFocus();
        }
    }

    Connections {
        target: Settings
        function onClipboardMaxItemsChanged() { root.restartWatchersForSettings(); }
        function onClipboardMaxBytesChanged() { root.restartWatchersForSettings(); }
    }

    Component.onCompleted: root.refresh()
}
