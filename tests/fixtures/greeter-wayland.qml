import QtQuick
import Quickshell
import Quickshell.Io
import qs.core
import qs.components
import qs.modules.lockscreen

ShellRoot {
    id: root
    function find(item, name) {
        if (item.objectName === name) return item;
        for (const child of item.children || []) {
            const found = find(child, name);
            if (found) return found;
        }
        return null;
    }
    function current() { return GreeterService.reviewWindows.find(window => window.screen.name === "LOGIN-A"); }
    function field() { return find(current().contentItem, "lockPassword"); }
    Variants {
        model: Quickshell.screens
        GreeterWindow { required property var modelData; screen: modelData }
    }
    // Only the lock VIEW is loaded, with an inert object. No LockService, PAM,
    // WlSessionLock, polkit, system D-Bus or desktop services exist in this test.
    PanelWindow {
        id: comparison
        visible: false
        implicitWidth: 1280
        implicitHeight: 720
        color: Theme.base
        property bool greeter: false
        QtObject {
            id: fakeAuth
            property bool secure: true
            property bool busy: false
            property bool fingerprintAvailable: true
            property string fingerprintState: "ready"
            property string message: ""
            signal clearPassword()
            function submit(value) {}
        }
        Loader {
            id: comparisonView
            anchors.fill: parent
            sourceComponent: comparison.greeter ? greeterView : lockView
        }
        Component {
            id: lockView
            LockView { auth: fakeAuth; wallpaperSource: GreeterConfig.wallpaperSource; animateEntrance: false }
        }
        Component {
            id: greeterView
            SessionAuthView {
                auth: fakeAuth; inputEnabled: true; animateEntrance: false
                wallpaperSource: GreeterConfig.wallpaperSource
                avatarSource: Settings.lockAvatarPath ? "file://" + Settings.lockAvatarPath : ""
            }
        }
    }
    IpcHandler {
        target: "greetertest"
        function state(): string {
            const windows = GreeterService.reviewWindows.filter(window => !!window);
            return JSON.stringify({available: GreeterService.available, user: GreeterService.selectedUser?.username || "",
                picker: GreeterService.usersOpen, client: GreeterService.reviewClient.state,
                accepted: GreeterService.accepted, queued: GreeterService.queuedResponse.length,
                busy: GreeterService.busy, echo: GreeterService.echoResponse, message: GreeterService.message,
                windows: windows.map(window => {
                    const view = find(window.contentItem, "reviewView");
                    const field = find(view, "lockPassword");
                    const avatar = find(view, "lockAvatar");
                    const frame = find(view, "lockPasswordFrame");
                    const list = find(window.contentItem, "greeterUsers");
                    const error = find(view, "lockError");
                    return {screen: window.screen.name, width: view.width, height: view.height,
                        field: [frame.x + field.x + field.width / 2, frame.y + field.height / 2],
                        avatar: [avatar.x + avatar.width / 2, avatar.y + avatar.height / 2],
                        groupCenter: (avatar.y + frame.y + frame.height) / 2,
                        frameSize: [frame.width, frame.height], length: field.length,
                        hiddenCursor: !!find(field, "hiddenPasswordCursor"), focused: field.activeFocus,
                        inputEnabled: field.enabled,
                        fieldVisible: field.visible,
                        fingerprintVisible: find(view, "lockFingerprint").visible,
                        errorVisible: error.visible, errorText: error.text,
                        listIndex: list ? list.currentIndex : -1, listFocus: list ? list.activeFocus : false};
                })});
        }
        function choose(index: int): void { GreeterService.chooseUser(GreeterConfig.users[index]); }
        function capture(path: string): void { find(current().contentItem, "reviewView").grabToImage(result => result.saveToFile(path)); }
        function compare(greeter: bool): void { comparison.greeter = greeter; comparison.visible = true; }
        function captureComparison(path: string): void { comparisonView.item.grabToImage(result => result.saveToFile(path)); }
        function endComparison(): void { comparison.visible = false; }
        function setText(value: string): void { field().text = value; }
        function fingerprint(): void { GreeterService.retryFingerprint(); }
    }
    Connections { target: GreeterService; function onSessionLaunched() { console.log("SYNTHETIC_SESSION_ACCEPTED"); } }
}
