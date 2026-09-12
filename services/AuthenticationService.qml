pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Polkit
import qs.core

Singleton {
    id: root

    readonly property var agent: agentLoader.active ? agentLoader.item : null
    readonly property bool registered: agent ? agent.isRegistered : false
    readonly property var flow: agent ? agent.flow : null
    readonly property var request: state.channels.find(channel => channel.ready && channel.mode !== "none") || state.channels.find(channel => channel.ready) || null
    readonly property bool active: !LockService.locked && !LockService.releasing && (flow !== null || request !== null)
    readonly property bool interactive: active && (flow !== null || request.mode !== "none")
    readonly property bool needsInput: active && (flow ? flow.isResponseRequired : request.mode === "input")
    readonly property bool responseVisible: flow ? flow.responseVisible : false
    readonly property string title: flow ? Strings.authSystem : request && request.mode === "none" ? Strings.authTouch : Strings.authSsh
    readonly property string message: Strings.authenticationText(flow ? flow.message : request ? request.message : "")
    readonly property string prompt: flow ? Strings.authenticationText(flow.inputPrompt) : Strings.authSecret
    readonly property string detail: flow ? flow.actionId : ""
    readonly property string supplementary: flow ? Strings.authenticationText(flow.supplementaryMessage) : ""
    readonly property bool error: flow ? flow.supplementaryIsError : false
    readonly property var identities: flow ? flow.identities : []
    readonly property string screenName: state.screenName
    readonly property int pendingCount: state.channels.length
    signal clearInput

    QtObject {
        id: state
        property var channels: []
        property string screenName: ""
    }

    LazyLoader {
        id: agentLoader
        active: Settings.polkitEnabled
        PolkitAgent {}
    }

    function present() {
        root.clearInput();
        if (LockService.locked || LockService.releasing) {
            root.cancelAll();
            return;
        }
        if (!root.active)
            return;
        state.screenName = SurfaceManager.focusedScreenName();
        if (root.interactive) {
            SurfaceManager.closeAllInternal();
            SurfaceManager.workspaceSwitcherVisible = false;
            if (ScreenshotService.active)
                ScreenshotService.cancel();
        }
    }
    onFlowChanged: present()
    onRequestChanged: present()
    onPromptChanged: clearInput()
    onNeedsInputChanged: clearInput()

    function submit(value) {
        if (!root.interactive)
            return;
        root.clearInput();
        if (root.flow) {
            if (root.flow.isResponseRequired)
                root.flow.submit(value);
        } else if (root.request) {
            root.request.finish(true, root.request.mode === "confirm" ? "yes" : value);
        }
    }
    function cancel() {
        root.clearInput();
        if (root.flow)
            root.flow.cancelAuthenticationRequest();
        else if (root.request)
            root.request.finish(false, "");
    }
    function cancelAll() {
        root.clearInput();
        for (const channel of state.channels.slice())
            channel.finish(false, "");
        if (root.flow)
            root.flow.cancelAuthenticationRequest();
    }
    function selectIdentity(index) {
        if (!root.flow || index < 0 || index >= root.identities.length)
            return;
        root.clearInput();
        root.flow.selectedIdentity = root.identities[index];
    }
    function remove(channel) {
        if (state.channels.indexOf(channel) < 0)
            return;
        state.channels = state.channels.filter(item => item !== channel);
        channel.destroy();
    }
    function receive(socketPath) {
        const prefix = Quickshell.env("XDG_RUNTIME_DIR") + "/qs-askpass-";
        if (!socketPath.startsWith(prefix) || !/^[a-zA-Z0-9_-]+\/socket$/.test(socketPath.slice(prefix.length)) || state.channels.length >= 8 || LockService.locked || LockService.releasing)
            return JSON.stringify({
                accepted: false
            });
        if (state.channels.some(channel => channel.path === socketPath))
            return JSON.stringify({
                accepted: false
            });
        const channel = connection.createObject(root, {
            path: socketPath
        });
        state.channels = state.channels.concat([channel]);
        channel.connected = true;
        return JSON.stringify({
            accepted: true,
            pid: Quickshell.processId
        });
    }

    Component {
        id: connection
        Socket {
            id: channel
            property bool ready: false
            property bool done: false
            property string mode: ""
            property string message: ""
            function finish(accepted, response) {
                if (done)
                    return;
                done = true;
                ready = false;
                channel.write(JSON.stringify({
                    accepted: accepted,
                    response: response
                }) + "\n");
                channel.flush();
                channel.connected = false;
                Qt.callLater(() => root.remove(channel));
            }
            onConnectionStateChanged: {
                if (!connected)
                    Qt.callLater(() => root.remove(channel));
            }
            onError: Qt.callLater(() => root.remove(channel))
            parser: SplitParser {
                onRead: data => {
                    if (data.length > 16384) {
                        channel.finish(false, "");
                        return;
                    }
                    try {
                        const value = JSON.parse(data);
                        if (value.closed === true) {
                            channel.finish(false, "");
                            return;
                        }
                        if (channel.ready || ["input", "confirm", "none"].indexOf(value.mode) < 0 || typeof value.message !== "string") {
                            channel.finish(false, "");
                            return;
                        }
                        channel.mode = value.mode;
                        channel.message = value.message;
                        channel.ready = true;
                    } catch (_) {
                        channel.finish(false, "");
                    }
                }
            }
            property Timer deadline: Timer {
                interval: 5000
                running: !channel.ready && !channel.done
                onTriggered: channel.finish(false, "")
            }
        }
    }
    Connections {
        target: LockService
        function onLockedChanged() {
            if (LockService.locked)
                root.cancelAll();
        }
    }
    IpcHandler {
        target: "authentication"
        function askpass(socketPath: string): string {
            return root.receive(socketPath);
        }
        function status(): string {
            return JSON.stringify({
                registered: root.registered,
                active: root.active,
                interactive: root.interactive,
                pending: root.pendingCount
            });
        }
    }
}
