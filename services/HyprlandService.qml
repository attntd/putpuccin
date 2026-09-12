pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io

Singleton {
    id: root

    property var lastToplevelByMonitor: ({})
    property var terminalContextByAddress: ({})
    property string lastContextTitle: ""
    property var queuedPathRequest: null
    property var resolvingRequest: null
    property int revision: 0
    property int pathRevision: 0

    readonly property string focusedMonitorName: Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""

    function monitorForScreen(screen) {
        return screen ? Hyprland.monitorFor(screen) : null;
    }

    function screenName(screen) {
        const monitor = root.monitorForScreen(screen);
        return monitor ? monitor.name : (screen ? screen.name : "");
    }

    function workspaceFor(id, screen) {
        root.revision;
        const monitor = root.monitorForScreen(screen);
        const values = Hyprland.workspaces ? Hyprland.workspaces.values : [];
        for (const workspace of values) {
            if (workspace.id === id && workspace.monitor && monitor && workspace.monitor.name === monitor.name)
                return workspace;
        }
        return null;
    }

    function workspaceOccupied(id, screen) {
        const workspace = root.workspaceFor(id, screen);
        return workspace !== null && workspace.toplevels && workspace.toplevels.values.length > 0;
    }

    function visibleWorkspaceIds(screen) {
        root.revision;
        const monitor = root.monitorForScreen(screen);
        if (!monitor)
            return [];

        let highestRelevantId = 0;
        const values = Hyprland.workspaces ? Hyprland.workspaces.values : [];
        for (const workspace of values) {
            const occupied = workspace.toplevels && workspace.toplevels.values.length > 0;
            if (occupied && workspace.id >= 1 && workspace.id <= 10 && workspace.monitor
                    && workspace.monitor.name === monitor.name)
                highestRelevantId = Math.max(highestRelevantId, workspace.id);
        }

        const activeId = monitor.activeWorkspace ? monitor.activeWorkspace.id : 0;
        if (activeId >= 1 && activeId <= 10)
            highestRelevantId = Math.max(highestRelevantId, activeId);

        const limit = Math.min(10, Math.max(1, highestRelevantId) + (highestRelevantId < 10 ? 1 : 0));
        const ids = [];
        for (let id = 1; id <= limit; id++)
            ids.push(id);
        return ids;
    }

    function dispatchFocusMonitor(monitorName) {
        if (!monitorName)
            return;
        if (Hyprland.usingLua)
            Hyprland.dispatch("hl.dsp.focus({ monitor = " + JSON.stringify(monitorName) + " })");
        else
            Hyprland.dispatch("focusmonitor " + monitorName);
    }

    function dispatchWorkspace(id) {
        if (Hyprland.usingLua) {
            Hyprland.dispatch("hl.dsp.focus({ workspace = " + JSON.stringify(String(id))
                + ", on_current_monitor = true })");
        } else {
            Hyprland.dispatch("workspace " + id);
        }
    }

    function activateWorkspace(id, screen) {
        const monitor = root.monitorForScreen(screen);
        const workspace = root.workspaceFor(id, screen);
        if (workspace) {
            workspace.activate();
        } else {
            if (monitor)
                root.dispatchFocusMonitor(monitor.name);
            root.dispatchWorkspace(id);
        }
    }

    function closeActiveWindow(screen) {
        const toplevel = root.activeToplevelFor(screen);
        const selector = root.liveWindowSelector(toplevel);
        if (!selector)
            return false;
        if (Hyprland.usingLua)
            Hyprland.dispatch("hl.dsp.window.close({ window = " + JSON.stringify(selector) + " })");
        else
            Hyprland.dispatch("closewindow " + selector);
        return true;
    }

    function moveActiveWindowToWorkspace(id, screen) {
        const selector = root.liveWindowSelector(root.activeToplevelFor(screen));
        if (!Number.isInteger(id) || id < 1 || id > 10 || !selector)
            return false;
        if (Hyprland.usingLua)
            Hyprland.dispatch("hl.dsp.window.move({ workspace = " + id
                + ", follow = false, window = " + JSON.stringify(selector) + " })");
        else
            Hyprland.dispatch("movetoworkspacesilent " + id + "," + selector);
        return true;
    }

    function normalizedAddress(address) {
        if (typeof address !== "string" || !/^(?:0x)?[0-9a-fA-F]{1,16}$/.test(address))
            return "";
        const normalized = address.replace(/^0x/, "").replace(/^0+/, "").toLowerCase();
        return normalized;
    }

    function liveWindowSelector(toplevel) {
        const values = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        const address = toplevel ? root.normalizedAddress(toplevel.address) : "";
        return address && values.indexOf(toplevel) >= 0 ? "address:0x" + address : "";
    }

    function activeWorkspace(screen) {
        const monitor = root.monitorForScreen(screen);
        return monitor ? monitor.activeWorkspace : null;
    }

    function hasFullscreen(screen) {
        const workspace = root.activeWorkspace(screen);
        return workspace ? workspace.hasFullscreen : false;
    }

    function rememberActiveToplevel() {
        const toplevel = Hyprland.activeToplevel;
        if (!toplevel || !toplevel.monitor)
            return;
        const next = Object.assign({}, root.lastToplevelByMonitor);
        next[toplevel.monitor.name] = toplevel;
        root.lastToplevelByMonitor = next;
        root.revision++;
        // Newly mapped windows can arrive through events before their full
        // class/PID metadata. Fetch once on focus, then react to the result.
        if (!toplevel.lastIpcObject || !toplevel.lastIpcObject.pid || !root.toplevelClass(toplevel))
            Hyprland.refreshToplevels();
        root.requestTerminalPath(toplevel);
    }

    function activeToplevelFor(screen) {
        root.revision;
        const monitor = root.monitorForScreen(screen);
        if (!monitor)
            return null;

        const remembered = root.lastToplevelByMonitor[monitor.name];
        if (remembered && root.liveWindowSelector(remembered) && remembered.monitor && remembered.monitor.name === monitor.name
                && remembered.workspace === monitor.activeWorkspace)
            return remembered;

        const workspace = monitor.activeWorkspace;
        const values = workspace && workspace.toplevels ? workspace.toplevels.values : [];
        return values.length > 0 ? values[values.length - 1] : null;
    }

    function toplevelClass(toplevel) {
        if (!toplevel || !toplevel.lastIpcObject)
            return "";
        return toplevel.lastIpcObject.class || toplevel.lastIpcObject.initialClass || "";
    }

    function isTerminal(toplevel) {
        const windowClass = root.toplevelClass(toplevel).toLocaleLowerCase();
        return windowClass.indexOf("kitty") >= 0 || windowClass.indexOf("foot") >= 0
            || windowClass.indexOf("alacritty") >= 0 || windowClass.indexOf("wezterm") >= 0
            || windowClass.indexOf("ghostty") >= 0 || windowClass.indexOf("konsole") >= 0
            || windowClass === "xterm" || windowClass === "rio";
    }

    function isBrowser(toplevel) {
        const windowClass = root.toplevelClass(toplevel).toLocaleLowerCase();
        return /(^|[.\s_-])(zen|firefox|librewolf|floorp|chromium|chrome|brave|vivaldi|opera|msedge)([.\s_-]|$)/.test(windowClass);
    }

    function contextApplicationId(toplevel) {
        const windowClass = root.toplevelClass(toplevel).toLowerCase();
        if (["zen", "zen-browser", "zen-browser-bin", "app.zen_browser.zen"].indexOf(windowClass) >= 0)
            return "zen";
        if (["com.github.iwalton3.jellyfin-mpv-shim", "jellyfin-mpv-shim", "jellyfin mpv shim"].indexOf(windowClass) >= 0)
            return "jellyfin";
        return "";
    }

    function cleanApplicationTitle(title, applicationId) {
        if (applicationId !== "zen" && applicationId !== "jellyfin")
            return title || "";
        const applicationName = applicationId === "zen" ? "Zen Browser" : "Jellyfin MPV Shim";
        const suffix = applicationId === "zen"
            ? /\s*[-–—·|]\s*Zen Browser\s*$/i
            : /\s*[-–—·|]\s*Jellyfin MPV Shim\s*$/i;
        const result = (title || "").trim();
        if (result.toLowerCase() === applicationName.toLowerCase())
            return "";
        // Strip one application decoration. An earlier identical suffix can
        // be a real part of the page or episode title and must be preserved.
        return result.replace(suffix, "").replace(/\s+$/, "");
    }

    function displayTitleFor(screen) {
        root.pathRevision;
        const toplevel = root.activeToplevelFor(screen);
        if (!toplevel)
            return "";
        const context = root.terminalContextByAddress[toplevel.address];
        if (root.isTerminal(toplevel)) {
            // Codex and other terminal CLIs put a changing Braille spinner in
            // the title. Keep the actual title/status as the path fallback.
            return (context ? context.cwd : "") || root.cleanTerminalTitle(toplevel.title);
        }
        return root.cleanApplicationTitle(toplevel.title, root.contextApplicationId(toplevel));
    }

    function cleanTerminalTitle(title) {
        return (title || "").replace(/^[\u2800-\u28ff]\s*/, "");
    }

    function terminalHostFor(screen) {
        root.pathRevision;
        const toplevel = root.activeToplevelFor(screen);
        if (!root.isTerminal(toplevel))
            return "";
        const context = root.terminalContextByAddress[toplevel.address];
        return context ? context.host : "";
    }

    function terminalCommandFor(screen) {
        root.pathRevision;
        const toplevel = root.activeToplevelFor(screen);
        if (!root.isTerminal(toplevel))
            return "";
        const context = root.terminalContextByAddress[toplevel.address];
        return context ? context.command : "";
    }

    function requestTerminalPath(toplevel) {
        if (!root.isTerminal(toplevel) || !toplevel.lastIpcObject)
            return;
        const pid = Number(toplevel.lastIpcObject.pid);
        if (!Number.isInteger(pid) || pid <= 0 || !toplevel.address)
            return;

        const request = { "address": toplevel.address, "pid": pid, "title": toplevel.title || "", "toplevel": toplevel };
        if (pathResolver.running) {
            root.queuedPathRequest = request;
            return;
        }
        root.startPathRequest(request);
    }

    function startPathRequest(request) {
        if (!root.pathRequestIsLive(request))
            return;
        root.resolvingRequest = request;
        pathTimeout.restart();
        pathResolver.exec([Quickshell.shellPath("scripts/terminal-context"), String(request.pid), request.title]);
    }

    function pathRequestIsLive(request) {
        return request && root.liveWindowSelector(request.toplevel)
            && request.toplevel.address === request.address && root.isTerminal(request.toplevel)
            && Number(request.toplevel.lastIpcObject.pid) === request.pid;
    }

    function pruneWindowContexts() {
        const values = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        const next = {};
        for (const toplevel of values) {
            const context = root.terminalContextByAddress[toplevel.address];
            if (context && root.isTerminal(toplevel) && context.ownerPid === Number(toplevel.lastIpcObject.pid))
                next[toplevel.address] = context;
        }
        root.terminalContextByAddress = next;
        const remembered = {};
        for (const monitorName of Object.keys(root.lastToplevelByMonitor)) {
            const toplevel = root.lastToplevelByMonitor[monitorName];
            if (values.indexOf(toplevel) >= 0)
                remembered[monitorName] = toplevel;
        }
        root.lastToplevelByMonitor = remembered;
        if (!root.pathRequestIsLive(root.queuedPathRequest))
            root.queuedPathRequest = null;
        if (root.resolvingRequest && !root.pathRequestIsLive(root.resolvingRequest)) {
            root.resolvingRequest = null;
            if (pathResolver.processId > 0)
                pathResolver.signal(9);
        }
        root.pathRevision++;
        root.revision++;
    }

    function finishPathRequest(exitCode) {
        pathTimeout.stop();
        const request = root.resolvingRequest;
        root.resolvingRequest = null;
        if (root.pathRequestIsLive(request)) {
            const next = Object.assign({}, root.terminalContextByAddress);
            delete next[request.address];
            try {
                const context = JSON.parse(pathOutput.text);
                if (exitCode === 0 && typeof context.host === "string" && context.host.length <= 253
                        && !/[\s<>]/.test(context.host) && typeof context.remote === "boolean"
                        && typeof context.cwd === "string" && context.cwd.length <= 4096
                        && typeof context.command === "string" && context.command.length <= 128
                        && (context.cwd === "" || context.cwd[0] === "/")) {
                    context.ownerPid = request.pid;
                    next[request.address] = context;
                }
            } catch (error) {
                // A failed helper clears its old context; the live title remains available.
            }
            root.terminalContextByAddress = next;
            root.pathRevision++;
        }
        if (root.queuedPathRequest)
            queuedPathStart.restart();
    }

    function requestPaste(address) {
        const normalized = root.normalizedAddress(address);
        const values = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        if (!normalized || !values.some(toplevel => root.normalizedAddress(toplevel.address) === normalized))
            return false;
        const selector = "address:0x" + normalized;
        if (Hyprland.usingLua) {
            Hyprland.dispatch("hl.dsp.send_shortcut({ mods = \"CTRL\", key = \"V\", window = "
                + JSON.stringify(selector) + " })");
        } else {
            Hyprland.dispatch("sendshortcut CTRL, V, " + selector);
        }
        return true;
    }

    Connections {
        target: Hyprland.toplevels
        function onValuesChanged() { root.pruneWindowContexts(); }
    }

    Connections {
        target: Hyprland
        function onActiveToplevelChanged() { root.rememberActiveToplevel(); }
        function onFocusedWorkspaceChanged() { root.revision++; }
        function onFocusedMonitorChanged() { root.revision++; }
    }

    Connections {
        target: Hyprland.activeToplevel
        function onLastIpcObjectChanged() {
            root.pruneWindowContexts();
            root.requestTerminalPath(Hyprland.activeToplevel);
        }
        function onTitleChanged() {
            root.revision++;
            const title = root.cleanTerminalTitle(Hyprland.activeToplevel ? Hyprland.activeToplevel.title : "");
            if (title !== root.lastContextTitle && root.isTerminal(Hyprland.activeToplevel))
                pathDebounce.restart();
            root.lastContextTitle = title;
        }
    }

    Connections {
        target: Hyprland.workspaces
        function onValuesChanged() { root.revision++; }
        function onObjectInsertedPost() { root.revision++; }
        function onObjectRemovedPost() { root.revision++; }
    }

    Timer {
        id: pathDebounce
        interval: 180
        onTriggered: root.requestTerminalPath(Hyprland.activeToplevel)
    }

    FileView {
        readonly property var terminal: Hyprland.activeToplevel
        readonly property int terminalPid: terminal && root.isTerminal(terminal)
            && terminal.lastIpcObject ? Number(terminal.lastIpcObject.pid) || 0 : 0
        path: terminalPid > 0 ? (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp")
            + "/quickshell-de-terminal/" + terminalPid + ".json" : ""
        watchChanges: true
        printErrors: false
        onFileChanged: pathDebounce.restart()
    }

    Timer {
        id: pathTimeout
        interval: 1000
        onTriggered: {
            if (pathResolver.processId > 0)
                pathResolver.signal(9);
            else
                root.finishPathRequest(-1);
        }
    }

    Timer {
        id: queuedPathStart
        interval: 0
        onTriggered: {
            const request = root.queuedPathRequest;
            root.queuedPathRequest = null;
            root.startPathRequest(request);
        }
    }

    Process {
        id: pathResolver
        stdout: StdioCollector {
            id: pathOutput
        }
        onStarted: {
            // Process.signal() must never see PID 0 while QProcess is starting.
            if (!root.pathRequestIsLive(root.resolvingRequest) && processId > 0)
                signal(9);
        }
        onExited: exitCode => root.finishPathRequest(exitCode)
        // FailedToStart only emits runningChanged in Quickshell 0.3.1.
        onRunningChanged: if (!running) Qt.callLater(() => {
            if (!pathResolver.running && root.resolvingRequest)
                root.finishPathRequest(-1);
        })
    }

    Component.onCompleted: root.rememberActiveToplevel()
}
