pragma Singleton

import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import qs.core

Singleton {
    id: root

    readonly property string directory: Settings.wallpaperDirectory || Settings.configHome + "/hypr/backgrounds"
    readonly property var wallpapers: state.files
    readonly property string currentSource: handoff.current
    readonly property bool loading: folder.status === FolderListModel.Loading
    readonly property bool rotating: rotation.running
    readonly property string errorMessage: state.error

    PersistentProperties {
        id: handoff
        reloadableId: "wallpaper-rotation-state"
        property string current: ""
        property double nextRotationAt: 0
        property int intervalMinutes: 0
    }

    QtObject {
        id: state
        property var files: []
        property var rejected: []
        property string error: ""
    }

    function schedule(reset = false) {
        if (!Settings.wallpaperEnabled) {
            handoff.nextRotationAt = 0;
            return;
        }
        if (loading || state.files.length - state.rejected.length < 2) return;
        if (reset || handoff.nextRotationAt <= 0
                || handoff.intervalMinutes !== Settings.wallpaperIntervalMinutes) {
            handoff.intervalMinutes = Settings.wallpaperIntervalMinutes;
            handoff.nextRotationAt = Date.now() + handoff.intervalMinutes * 60 * 1000;
        }
    }

    function refresh() {
        if (loading) return;
        const files = [];
        for (let i = 0; i < folder.count; i++)
            files.push(String(folder.get(i, "fileUrl")));
        state.files = files;
        state.rejected = [];
        state.error = files.length ? "" : "Wallpaper directory is empty or unavailable: " + directory;
        if (files.indexOf(handoff.current) < 0)
            handoff.current = files.length ? files[0] : "";
        schedule();
    }

    function next() {
        if (!Settings.wallpaperEnabled || loading || !state.files.length) return;
        const start = state.files.indexOf(handoff.current);
        for (let step = 1; step <= state.files.length; step++) {
            const candidate = state.files[(start + step) % state.files.length];
            if (state.rejected.indexOf(candidate) < 0) {
                handoff.current = candidate;
                schedule(true);
                return;
            }
        }
    }

    function reject(source) {
        if (!source || state.rejected.indexOf(source) >= 0) return;
        state.rejected = state.rejected.concat([source]);
        state.error = "Cannot load wallpaper: " + source;
        console.warn(state.error);
        if (source === handoff.current) Qt.callLater(root.next);
    }


    FolderListModel {
        id: folder
        folder: "file://" + root.directory.split("/").map(encodeURIComponent).join("/")
        nameFilters: ["*.jpg", "*.jpeg", "*.png", "*.webp", "*.jxl"]
        caseSensitive: false
        showDirs: false
        showOnlyReadable: true
        sortField: FolderListModel.Name
        sortCaseSensitive: false
        onCountChanged: rescan.restart()
        onStatusChanged: rescan.restart()
    }

    Connections {
        target: folder
        function onDataChanged() { rescan.restart(); }
        function onModelReset() { rescan.restart(); }
    }

    Timer {
        id: rescan
        interval: 50
        onTriggered: root.refresh()
    }

    Timer {
        id: rotation
        interval: Math.max(1, handoff.nextRotationAt - Date.now())
        running: Settings.wallpaperEnabled && !root.loading
            && state.files.length - state.rejected.length > 1
            && handoff.nextRotationAt > 0
        repeat: true
        onTriggered: root.next()
    }

    Connections {
        target: Settings
        function onWallpaperEnabledChanged() { root.schedule(); }
        function onWallpaperIntervalMinutesChanged() { root.schedule(); }
    }

    IpcHandler {
        target: "wallpaper"
        function next(): void { root.next(); }
        function status(): string {
            return JSON.stringify({directory: root.directory, files: root.wallpapers,
                current: root.currentSource, loading: root.loading, rotating: root.rotating,
                enabled: Settings.wallpaperEnabled,
                intervalMinutes: Settings.wallpaperIntervalMinutes,
                nextRotationAt: handoff.nextRotationAt,
                transitionDuration: Settings.reducedMotion ? Motion.fast : Settings.wallpaperTransitionDuration,
                error: root.errorMessage});
        }
    }
}
