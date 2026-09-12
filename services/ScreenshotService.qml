pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.core
import ScreenshotNative as Native

Singleton {
    id: root

    readonly property string phase: state.phase
    readonly property bool active: phase !== "idle"
    readonly property string mode: state.mode
    readonly property string screenName: state.screenName
    readonly property var screens: state.screens
    readonly property var windows: state.windows
    readonly property var selection: state.selection
    readonly property bool hasSelection: selection !== null && selection.width > 0 && selection.height > 0
    readonly property string errorMessage: state.errorMessage
    readonly property bool editorAvailable: state.editorAvailable
    readonly property string directory: state.directory
    readonly property int generation: state.generation
    readonly property bool paintCursor: state.paintCursor
    readonly property int lastStartupMs: state.lastStartupMs
    readonly property string lastSavedPath: state.lastSavedPath
    readonly property string helperPath: Quickshell.shellPath("scripts/screenshot-action")

    signal captureStarting(int token)

    QtObject {
        id: state
        property string phase: "idle"
        property string mode: "region"
        property string screenName: ""
        property var screens: []
        property var windows: []
        property var selection: null
        property string errorMessage: ""
        property bool editorAvailable: false
        property bool paintCursor: false
        property string directory: ""
        property int generation: 0
        property var monitors: null
        property var clients: null
        property var requests: []
        property var holds: ({})
        property var exportRect: null
        property string operation: ""
        property string workerDirectory: ""
        property string action: ""
        property double startedAt: 0
        property var presentedScreens: ({})
        property int lastStartupMs: -1
        property string lastSavedPath: ""
    }

    function recordFor(name) {
        return state.screens.find(item => item.name === name) || null;
    }

    function fileUrl(path) {
        return "file://" + path.split("/").map(part => encodeURIComponent(part)).join("/");
    }

    function begin(nextMode = "region", requestedScreen = "") {
        if (AuthenticationService.interactive) return false;
        if (LockService.locked || LockService.releasing) {
            state.errorMessage = Strings.screenshotLocked;
            return false;
        }
        if (["region", "window", "monitor"].indexOf(nextMode) < 0)
            return false;
        // A repeated shortcut cancels the current interaction, never races a
        // second grab or a filesystem operation against the first one.
        if (root.active) {
            root.cancel();
            return true;
        }
        if (worker.running || encoder.busy || !Quickshell.screens.length || !Hyprland.requestSocketPath) {
            state.errorMessage = Strings.screenshotUnavailable;
            return false;
        }
        state.startedAt = Date.now();
        state.presentedScreens = ({});
        state.lastStartupMs = -1;
        state.generation++;
        state.errorMessage = "";
        state.selection = null;
        state.windows = [];
        state.mode = nextMode;
        state.paintCursor = Settings.screenshotPaintCursor;
        state.editorAvailable = encoder.hasEditor();
        state.screenName = requestedScreen || (Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : "");
        state.screens = Array.from(Quickshell.screens).map((screen, index) => ({
            name: screen.name, x: screen.x, y: screen.y,
            width: screen.width, height: screen.height,
            devicePixelRatio: screen.devicePixelRatio, orientation: screen.orientation,
            pixelWidth: 0, pixelHeight: 0, url: "", grab: null, basename: "screen-" + index + ".png"
        }));
        if (!root.recordFor(state.screenName))
            state.screenName = state.screens[0].name;
        state.monitors = null;
        state.clients = null;
        state.holds = ({});
        state.exportRect = null;
        state.phase = "preparing";
        deadline.interval = 6000;
        deadline.restart();
        root.captureStarting(generation);
        root.requestMetadata("monitors");
        root.requestMetadata("clients");
        return true;
    }

    // The native toplevel model has no transactional geometry refresh signal.
    // Two one-shot native sockets provide complete monitor/workspace and client
    // rectangles for this frozen frame. They are closed before selection begins.
    function requestMetadata(kind) {
        const request = metadataRequest.createObject(root, {kind: kind, token: generation});
        state.requests = state.requests.concat([request]);
        request.connected = true;
    }

    function metadata(kind, text, token) {
        if (token !== generation || phase !== "preparing")
            return;
        let data;
        try { data = JSON.parse(text); } catch (_) { return; }
        if (!Array.isArray(data)) {
            root.fail(Strings.screenshotUnavailable);
            return;
        }
        if (kind === "monitors") state.monitors = data;
        else state.clients = data;
        root.maybeCapture();
    }

    function closeRequests() {
        const requests = state.requests;
        state.requests = [];
        for (const request of requests) {
            request.connected = false;
            request.destroy();
        }
    }

    // The UI holds capture only until a panel's final collapsed frame. Normal
    // Print has no fixed settling delay and storage preparation runs in parallel.
    function holdCapture(id, token) {
        if (token !== generation || phase !== "preparing") return;
        state.holds = Object.assign({}, state.holds, {[id]: true});
    }

    function releaseCapture(id, token) {
        if (token !== generation || phase !== "preparing") return;
        const holds = Object.assign({}, state.holds);
        delete holds[id];
        state.holds = holds;
        root.maybeCapture();
    }

    function maybeCapture() {
        if (phase !== "preparing" || Object.keys(state.holds).length > 0
                || state.monitors === null || state.clients === null)
            return;
        root.closeRequests();
        const windows = [];
        const visibleWorkspaces = new Set();
        const specialWorkspaces = new Set();
        for (const monitor of state.monitors) {
            if (monitor.disabled || monitor.dpmsStatus === false) continue;
            if (monitor.activeWorkspace) visibleWorkspaces.add(monitor.activeWorkspace.id);
            if (monitor.specialWorkspace && monitor.specialWorkspace.id) {
                visibleWorkspaces.add(monitor.specialWorkspace.id);
                specialWorkspaces.add(monitor.specialWorkspace.id);
            }
        }
        const clients = state.clients.slice().sort((left, right) => {
            // Floating windows appear above tiles; focus order breaks ties.
            if (Boolean(left.floating) !== Boolean(right.floating))
                return left.floating ? -1 : 1;
            return (left.focusHistoryID < 0 ? 99999 : left.focusHistoryID)
                - (right.focusHistoryID < 0 ? 99999 : right.focusHistoryID);
        });
        for (const screen of state.screens) {
            const monitor = state.monitors.find(item => item.name === screen.name);
            if (!monitor || monitor.disabled || monitor.dpmsStatus === false) {
                root.fail(Strings.screenshotScreenChanged);
                return;
            }
            for (const client of clients) {
                if (!client.mapped || client.hidden || !client.at || !client.size || !client.workspace)
                    continue;
                const workspace = client.workspace.id;
                if (!client.pinned && !visibleWorkspaces.has(workspace))
                    continue;
                const x = Math.max(0, client.at[0] - screen.x);
                const y = Math.max(0, client.at[1] - screen.y);
                const right = Math.min(screen.width, client.at[0] - screen.x + client.size[0]);
                const bottom = Math.min(screen.height, client.at[1] - screen.y + client.size[1]);
                if (right <= x || bottom <= y)
                    continue;
                windows.push({id: client.address + ":" + screen.name,
                    title: client.title || client.class || Strings.window,
                    screenName: screen.name, x: x, y: y, width: right - x, height: bottom - y,
                    special: specialWorkspaces.has(workspace), order: windows.length});
            }
        }
        // A visible special workspace is above the regular workspace.
        // QV4 Array.sort does not preserve equal elements' order. Keep the
        // original stacking order explicitly when promoting special windows.
        state.windows = windows.sort((a, b) => Number(b.special) - Number(a.special) || a.order - b.order);
        state.monitors = null;
        state.clients = null;
        state.phase = "capturing";
    }

    function captured(name, width, height, token, grab) {
        if (token !== generation || phase !== "capturing")
            return;
        const record = root.recordFor(name);
        if (!record || !grab || !grab.url || width <= 0 || height <= 0) {
            root.fail(Strings.screenshotCaptureFailed);
            return;
        }
        state.screens = state.screens.map(screen => screen.name === name
            ? Object.assign({}, screen, {pixelWidth: width, pixelHeight: height,
                url: String(grab.url), grab: grab}) : screen);
        if (state.screens.every(screen => screen.url.length > 0)) {
            deadline.stop();
            state.phase = "selecting";
            if (mode === "monitor") root.selectMonitor(screenName);
            if (mode === "window") root.selectFirstWindow();
        }
    }

    // Record the first submitted frame of every ready overlay. This diagnostic
    // is event-driven and is retained after cancel; it never records pixels.
    function presented(name) {
        if (!active || !root.recordFor(name) || state.presentedScreens[name]) return;
        state.presentedScreens = Object.assign({}, state.presentedScreens, {[name]: true});
        if (screens.every(screen => state.presentedScreens[screen.name]))
            state.lastStartupMs = Date.now() - state.startedAt;
    }

    function setMode(value) {
        if (phase !== "selecting" || ["region", "window", "monitor"].indexOf(value) < 0)
            return;
        state.mode = value;
        state.selection = null;
        state.errorMessage = "";
        if (value === "monitor") root.selectMonitor(screenName);
        if (value === "window") root.selectFirstWindow();
    }

    function focusScreen(name) {
        if (phase === "selecting" && root.recordFor(name))
            state.screenName = name;
    }

    function selectFirstWindow() {
        const window = state.windows.find(item => item.screenName === screenName);
        if (window) root.selectWindow(window.id);
        else state.errorMessage = Strings.screenshotNoWindow;
    }

    function selectRegion(name, x, y, width, height) {
        if (phase !== "selecting") return false;
        const screen = root.recordFor(name);
        if (!screen || ![x, y, width, height].every(Number.isFinite)) return false;
        const left = Math.max(0, Math.min(screen.width, Math.min(x, x + width)));
        const top = Math.max(0, Math.min(screen.height, Math.min(y, y + height)));
        const right = Math.max(left, Math.min(screen.width, Math.max(x, x + width)));
        const bottom = Math.max(top, Math.min(screen.height, Math.max(y, y + height)));
        state.selection = right > left && bottom > top
            ? {screenName: name, x: left, y: top, width: right - left, height: bottom - top} : null;
        state.screenName = name;
        state.errorMessage = "";
        return state.selection !== null;
    }

    function selectWindow(id) {
        const window = state.windows.find(item => item.id === id);
        if (!window || phase !== "selecting") return false;
        return root.selectRegion(window.screenName, window.x, window.y, window.width, window.height);
    }

    function selectMonitor(name) {
        const screen = root.recordFor(name);
        if (!screen || phase !== "selecting") return false;
        return root.selectRegion(name, 0, 0, screen.width, screen.height);
    }

    function perform(action) {
        if (phase !== "selecting" || !hasSelection || ["copy", "save", "edit"].indexOf(action) < 0)
            return false;
        if (action === "edit" && !editorAvailable) {
            state.errorMessage = Strings.screenshotEditorMissing;
            return false;
        }
        const screen = root.recordFor(selection.screenName);
        const sx = screen.pixelWidth / screen.width;
        const sy = screen.pixelHeight / screen.height;
        const x = Math.max(0, Math.floor(selection.x * sx));
        const y = Math.max(0, Math.floor(selection.y * sy));
        const right = Math.min(screen.pixelWidth, Math.ceil((selection.x + selection.width) * sx));
        const bottom = Math.min(screen.pixelHeight, Math.ceil((selection.y + selection.height) * sy));
        state.action = action;
        state.errorMessage = "";
        state.phase = "exporting";
        deadline.interval = 15000;
        deadline.restart();
        state.exportRect = {screenName: screen.name, x: x, y: y,
            width: right - x, height: bottom - y};
        if (!directory) root.runHelper("prepare", ["prepare", String(Quickshell.processId)]);
        else root.exportSelection();
        return true;
    }

    function exportSelection() {
        if (phase !== "exporting" || !directory || worker.running || encoder.busy) return;
        const rect = state.exportRect;
        const screen = rect ? root.recordFor(rect.screenName) : null;
        if (!screen || !encoder.write(screen.grab, directory, rect.x, rect.y, rect.width, rect.height, generation)) {
            deadline.stop();
            state.phase = "selecting";
            state.errorMessage = Strings.screenshotExportFailed;
        }
    }

    Native.ImageExporter {
        id: encoder
        onFinished: (token, ok, cancelled) => {
            if (token !== root.generation || root.phase !== "exporting") return;
            if (!ok) {
                deadline.stop();
                state.phase = "selecting";
                state.errorMessage = Strings.screenshotExportFailed;
                return;
            }
            state.phase = "working";
            deadline.restart();
            root.runHelper("finish", ["finish", state.action, root.directory, Settings.screenshotDirectory,
                Strings.screenshotSaved, Strings.screenshotSavedBody, Strings.screenshotOpen]);
        }
    }

    // Event-driven helpers only: no polling. The child has its own shorter
    // deadlines; the service watchdog also covers failed process startup.
    function runHelper(operation, args) {
        state.operation = operation;
        state.workerDirectory = directory;
        worker.command = [root.helperPath].concat(args);
        worker.running = true;
    }

    function helperFinished(exitCode, output) {
        const operation = state.operation;
        const workerDirectory = state.workerDirectory;
        state.operation = "";
        state.workerDirectory = "";
        let result;
        try { result = JSON.parse(output); } catch (_) { result = {ok: false}; }
        if (!active) {
            if (operation === "prepare" && result.directory)
                root.cleanup(result.directory);
            else root.cleanup(workerDirectory);
            return;
        }
        if (exitCode !== 0 || !result.ok) {
            const message = root.actionError(result.code, operation);
            deadline.stop();
            state.phase = "selecting";
            state.errorMessage = message;
            return;
        }
        if (operation === "prepare") {
            state.directory = result.directory;
            state.editorAvailable = result.editorAvailable === true;
            root.exportSelection();
        } else if (operation === "finish") {
            if (result.path && state.action === "save") state.lastSavedPath = result.path;
            root.cancel();
        }
    }

    function actionError(code, operation) {
        if (code === "editor_missing") return Strings.screenshotEditorMissing;
        if (code === "clipboard_missing") return Strings.screenshotClipboardMissing;
        if (code === "save_failed" || code === "invalid_destination") return Strings.screenshotSaveFailed;
        if (operation === "prepare") return Strings.screenshotPrepareFailed;
        if (operation === "crop") return Strings.screenshotExportFailed;
        return Strings.screenshotActionFailed;
    }

    function cleanup(path) {
        if (path) Quickshell.execDetached([root.helperPath, "cleanup", path]);
    }

    function cancel() {
        const path = state.directory;
        state.generation++;
        state.phase = "idle";
        if (worker.running) worker.running = false;
        deadline.stop();
        encoder.cancel();
        state.holds = ({});
        state.exportRect = null;
        root.closeRequests();
        // SIGTERM lets the helper unwind its bounded operation. Cleanup also
        // waits for a short in-flight action if QML is reloaded before exited.
        state.directory = "";
        state.screens = [];
        state.windows = [];
        state.selection = null;
        state.monitors = null;
        state.clients = null;
        root.cleanup(path);
    }

    function fail(message) {
        state.errorMessage = message;
        root.cancel();
        Quickshell.execDetached(["notify-send", "--app-name=QuickShell", "--icon=camera-photo",
            "--hint=boolean:transient:true", Strings.screenshot, message]);
    }

    function checkScreens() {
        if (!active) return;
        const actual = Array.from(Quickshell.screens);
        if (actual.length !== screens.length || screens.some(record => !actual.some(screen =>
                screen.name === record.name && screen.x === record.x && screen.y === record.y
                && screen.width === record.width && screen.height === record.height
                && screen.devicePixelRatio === record.devicePixelRatio && screen.orientation === record.orientation)))
            root.fail(Strings.screenshotScreenChanged);
    }

    Component {
        id: metadataRequest
        Socket {
            id: request
            required property string kind
            required property int token
            path: Hyprland.requestSocketPath
            onConnectedChanged: if (connected) { write("j/" + kind); flush(); }
            parser: StdioCollector {
                waitForEnd: false
                onTextChanged: {
                    if (text.length > 2097152) root.fail(Strings.screenshotUnavailable);
                    else {
                        try { JSON.parse(text); } catch (_) { return; }
                        // Hyprland closes a one-shot IPC connection after its
                        // reply. Disconnect once JSON is complete so Qt does
                        // not treat that normal EOF as PeerClosedError.
                        request.connected = false;
                        root.metadata(request.kind, text, request.token);
                    }
                }
            }
        }
    }

    Process {
        id: worker
        stdout: StdioCollector { id: helperOutput }
        stderr: StdioCollector {}
        onExited: (exitCode, exitStatus) => root.helperFinished(exitCode, helperOutput.text)
    }
    Timer {
        id: deadline
        onTriggered: {
            // A stalled helper must not keep the service unavailable forever.
            // Detached editor/notification workers have their own lifetimes.
            if (worker.running) worker.signal(9);
            if (phase === "preparing" || phase === "capturing") root.fail(Strings.screenshotCaptureTimeout);
            else root.fail(Strings.screenshotActionFailed);
        }
    }
    Connections {
        target: Quickshell
        function onScreensChanged() { root.checkScreens(); }
    }
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            // Qt does not report a Hyprland 180-degree output transform as a
            // geometry/orientation change. A compositor config reload must
            // invalidate the frozen coordinate system as well.
            if (root.active && ["configreloaded", "monitoradded", "monitoraddedv2", "monitorremoved"].indexOf(event.name) >= 0)
                root.fail(Strings.screenshotScreenChanged);
        }
    }
    Connections {
        target: LockService
        function onLockedChanged() { if (LockService.locked) root.cancel(); }
        function onReleasingChanged() { if (LockService.releasing) root.cancel(); }
    }
    Component.onDestruction: root.cleanup(state.directory)

    // Hyprland invokes these directly without starting the qs command process.
    // Keep IPC for scripts and the shared actions used by panels.
    GlobalShortcut {
        appid: "quickshell-de"
        name: "screenshot-open"
        description: "Screenshot menu"
        onPressed: root.begin("region")
    }
    GlobalShortcut {
        appid: "quickshell-de"
        name: "screenshot-region"
        description: "Screenshot region"
        onPressed: root.begin("region")
    }
    GlobalShortcut {
        appid: "quickshell-de"
        name: "screenshot-window"
        description: "Screenshot window"
        onPressed: root.begin("window")
    }
    GlobalShortcut {
        appid: "quickshell-de"
        name: "screenshot-monitor"
        description: "Screenshot monitor"
        onPressed: root.begin("monitor")
    }

    IpcHandler {
        target: "screenshot"
        function open(): bool { return root.begin("region"); }
        function region(): bool { return root.begin("region"); }
        function window(): bool { return root.begin("window"); }
        function monitor(): bool { return root.begin("monitor"); }
        function cancel(): void { root.cancel(); }
        function status(): string {
            return JSON.stringify({active: root.active, phase: root.phase, mode: root.mode,
                screenName: root.screenName, hasSelection: root.hasSelection, selection: root.selection,
                editorAvailable: root.editorAvailable, errorMessage: root.errorMessage,
                lastSavedPath: root.lastSavedPath, lastStartupMs: root.lastStartupMs,
                screens: root.screens.map(screen => ({name: screen.name, width: screen.width,
                    height: screen.height, pixelWidth: screen.pixelWidth, pixelHeight: screen.pixelHeight}))});
        }
    }
}
