pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pam
import qs.core

Singleton {
    id: root
    readonly property bool locked: handoff.locked
    readonly property bool secure: state.secure
    readonly property bool busy: passwordPam.active || state.authenticated
    readonly property bool authenticating: passwordPam.active
    readonly property bool releasing: state.releasing
    readonly property bool fadingOut: state.fadingOut
    readonly property var exitFrames: state.exitFrames
    readonly property int generation: state.generation
    readonly property int fadeDuration: Settings.reducedMotion ? Motion.fast : Motion.lockFade
    readonly property bool fingerprintAvailable: state.fingerprintAvailable
    readonly property string fingerprintState: state.fingerprintState
    readonly property string message: state.message
    readonly property string wallpaperSource: handoff.wallpaper
    signal clearPassword()

    PersistentProperties {
        id: handoff
        reloadableId: "session-lock-state"
        property bool locked: false
        property bool watchFiles: true
        property string wallpaper: ""
    }
    QtObject {
        id: state
        property bool secure: false
        property bool fingerprintAvailable: false
        property string fingerprintState: "ready"
        property string message: ""
        property string password: ""
        property bool responded: false
        property bool authenticated: false
        property bool releasing: false
        property bool fadingOut: false
        property var readyScreens: ({})
        property var exitFrames: ({})
        property int generation: 0
    }

    function lock() {
        if (root.locked) return;
        const resumeWatching = state.releasing ? handoff.watchFiles : Quickshell.watchFiles;
        releaseDeadline.stop();
        fadeFinished.stop();
        state.releasing = false;
        state.fadingOut = false;
        state.authenticated = false;
        state.readyScreens = ({});
        state.exitFrames = ({});
        state.generation++;
        state.fingerprintState = "ready";
        handoff.wallpaper = WallpaperService.currentSource;
        handoff.watchFiles = resumeWatching;
        Quickshell.watchFiles = false;
        SurfaceManager.closeAllInternal();
        SurfaceManager.workspaceSwitcherVisible = false;
        handoff.locked = true;
    }

    function setSecure(value) {
        if (state.secure === value) return;
        state.secure = value;
        if (value) {
            state.message = "";
            fingerprintProbe.running = true;
        } else {
            passwordPam.abort();
            fingerprintPam.abort();
            fingerprintProbe.running = false;
            retryFingerprint.stop();
            successDelay.stop();
            state.password = "";
            if (!state.authenticated) state.fingerprintAvailable = false;
            root.clearPassword();
        }
    }

    function submit(password) {
        if (!root.secure || root.busy || !password.length) return;
        state.message = "";
        state.password = password;
        state.responded = false;
        root.clearPassword();
        if (!passwordPam.start()) {
            state.password = "";
            state.message = Strings.lockAuthUnavailable;
        }
    }

    function accepted(fingerprint) {
        if (!root.secure || state.authenticated) return;
        state.authenticated = true;
        state.password = "";
        root.clearPassword();
        if (fingerprint) state.fingerprintState = "success";
        state.message = "";
        retryFingerprint.stop();
        successDelay.start();
        passwordPam.abort();
        fingerprintPam.abort();
    }

    PamContext {
        id: passwordPam
        config: "system-auth"
        onPamMessage: {
            if (!responseRequired) return;
            if (!root.secure || state.responded || responseVisible) {
                state.password = "";
                abort();
                state.message = Strings.lockAuthUnavailable;
                return;
            }
            state.responded = true;
            respond(state.password);
            state.password = "";
        }
        onCompleted: result => {
            state.password = "";
            if (!root.secure || state.authenticated) return;
            if (result === PamResult.Success) root.accepted(false);
            else state.message = result === PamResult.Error ? Strings.lockAuthUnavailable : Strings.lockPasswordFailed;
        }
    }
    PamContext {
        id: fingerprintPam
        config: "fingerprint"
        configDirectory: Quickshell.shellPath("assets/pam")
        onCompleted: result => {
            if (!root.secure || state.authenticated) return;
            if (result === PamResult.Success) root.accepted(true);
            else if (result === PamResult.Error) {
                state.fingerprintAvailable = false;
                state.message = Strings.lockAuthUnavailable;
            } else {
                state.fingerprintState = "failure";
                state.message = Strings.lockFingerprintFailed;
                retryFingerprint.restart();
            }
        }
    }
    Process {
        id: fingerprintProbe
        command: [Quickshell.shellPath("scripts/fingerprint-enrolled")]
        stdout: StdioCollector { id: enrollment }
        onExited: code => {
            if (!root.secure) return;
            state.fingerprintAvailable = code === 0 && enrollment.text.trim() === "true";
            if (state.fingerprintAvailable) {
                state.fingerprintState = "ready";
                fingerprintPam.start();
            }
        }
    }
    Timer {
        id: retryFingerprint
        interval: 1200
        onTriggered: {
            state.fingerprintState = "ready";
            if (state.message === Strings.lockFingerprintFailed) state.message = "";
            if (root.secure && !state.authenticated) fingerprintPam.start();
        }
    }
    Timer {
        id: successDelay
        interval: Motion.elaborate
        onTriggered: {
            if (!root.secure) return;
            state.readyScreens = ({});
            state.releasing = true;
            releaseDeadline.start();
        }
    }
    // Only an authenticated session may hand off to the cosmetic exit layer.
    function exitCaptured(screenName, generation, result) {
        if (!state.authenticated || !root.locked || !state.releasing
                || generation !== state.generation || !result || !result.url) return;
        const frames = Object.assign({}, state.exitFrames);
        frames[screenName] = result;
        state.exitFrames = frames;
    }
    function exitFrameReady(screenName) {
        if (!state.authenticated || !state.releasing || state.fadingOut) return;
        const screens = Object.assign({}, state.readyScreens);
        screens[screenName] = true;
        state.readyScreens = screens;
        if (Quickshell.screens.every(screen => screens[screen.name])) {
            if (root.locked) releaseLock();
            else {
                state.readyScreens = ({});
                state.fadingOut = true;
                fadeFinished.restart();
            }
        }
    }
    function releaseLock() {
        if (!state.authenticated || !root.secure || state.fadingOut) return;
        releaseDeadline.stop();
        state.readyScreens = ({});
        handoff.locked = false;
        root.setSecure(false);
        // Also bounds the wait for an output that disappears during handoff.
        fadeFinished.start();
    }
    function exitFadeFinished(screenName) {
        if (!state.authenticated || !state.fadingOut) return;
        const screens = Object.assign({}, state.readyScreens);
        screens[screenName] = true;
        state.readyScreens = screens;
        if (Quickshell.screens.every(screen => screens[screen.name])) finishRelease();
    }
    function finishRelease() {
        if (!state.authenticated || root.locked) return;
        fadeFinished.stop();
        state.releasing = false;
        state.fadingOut = false;
        state.exitFrames = ({});
        state.readyScreens = ({});
        state.authenticated = false;
        state.fingerprintAvailable = false;
        Quickshell.watchFiles = handoff.watchFiles;
    }
    Timer {
        id: releaseDeadline
        // A failed output must not strand an already authenticated user.
        interval: 1000
        onTriggered: root.releaseLock()
    }
    Timer {
        id: fadeFinished
        interval: root.fadeDuration + 1000
        onTriggered: root.finishRelease()
    }
    IpcHandler {
        target: "lockscreen"
        function lock(): void { root.lock(); }
        function status(): string {
            return JSON.stringify({locked:root.locked, secure:root.secure,
                fingerprintAvailable:root.fingerprintAvailable, fingerprintState:root.fingerprintState, busy:root.busy, releasing:root.releasing, fadingOut:root.fadingOut});
        }
    }
    Component.onDestruction: {
        state.password = "";
        passwordPam.abort();
        fingerprintPam.abort();
    }
}
