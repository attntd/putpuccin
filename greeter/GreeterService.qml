pragma Singleton
import QtQuick
import Quickshell
import GreeterNative
import qs.core

Singleton {
    id: root
    property var selectedUser: null
    property bool usersOpen: false
    readonly property bool available: client.connected && GreeterConfig.ready && !!selectedUser
    readonly property bool busy: submitted || (client.state === "cancelling" && !fingerprintRestarting)
        || client.state === "launching" || accepted
    property bool fingerprintAvailable: !!selectedUser && selectedUser.fingerprint === true
    property string fingerprintState: "ready"
    property bool fingerprintTimedOut: false
    property bool fingerprintExpired: false
    property bool fingerprintRestarting: false
    property string message: GreeterConfig.error
    property bool echoResponse: false
    property bool submitted: false
    property bool accepted: false
    property bool autoStart: false
    property string queuedResponse: ""
    readonly property url avatarSource: selectedUser && selectedUser.avatar === true
        ? Qt.resolvedUrl("assets/avatars/" + selectedUser.username + ".png") : ""
    signal clearPassword()
    signal sessionLaunched()
    signal restartRequested()

    function chooseUser(user) {
        if (!user || client.state === "launching" || client.state === "launched") return;
        if (selectedUser && selectedUser.username === user.username
                && client.state === "authenticating" && !accepted) {
            // Closing the chooser on the same account must not cancel its PAM
            // conversation (some password stacks count a cancelled prompt).
            usersOpen = false;
            return;
        }
        successDelay.stop();
        fingerprintRestarting = false;
        queuedResponse = "";
        submitted = accepted = false;
        clearPassword();
        selectedUser = user;
        usersOpen = false;
        message = "";
        fingerprintAvailable = user.fingerprint === true;
        fingerprintState = "ready";
        fingerprintTimedOut = false;
        fingerprintExpired = false;
        echoResponse = false;
        autoStart = fingerprintAvailable;
        client.cancel();
        maybeStart();
    }
    function maybeStart() {
        if (autoStart && available && client.state === "idle") {
            autoStart = false;
            client.begin(selectedUser.username);
        }
    }
    function openUsers() {
        if (client.state === "launching" || client.state === "launched") return;
        successDelay.stop();
        const wasAccepted = accepted;
        accepted = false;
        queuedResponse = "";
        clearPassword();
        usersOpen = true;
        if (wasAccepted) client.cancel();
    }
    function retryFingerprint() {
        if (!available || usersOpen || busy) return;
        queuedResponse = "";
        message = "";
        clearPassword();
        fingerprintState = "ready";
        fingerprintTimedOut = false;
        fingerprintExpired = false;
        client.begin(selectedUser.username);
    }
    function submit(value) {
        if (!available || usersOpen || busy || !value.length || value.length > 4096) return;
        message = "";
        submitted = true;
        clearPassword();
        if (client.responseRequired) {
            client.respond(value);
        } else {
            queuedResponse = value;
            if (client.state === "idle") client.begin(selectedUser.username);
        }
    }

    GreetdClient {
        id: client
        onChanged: {
            if (client.state === "authenticating" || client.state === "unavailable")
                root.fingerprintRestarting = false;
            root.maybeStart();
        }
        onAuthMessage: (prompt, error, responseRequired, echoResponse) => {
            const text = prompt.trim();
            if (text === "GREETER_FINGERPRINT_DONE" && !responseRequired) {
                // Only this fail-closed PAM boundary is safe to cancel: a
                // cancelled password prompt could increment the account tally.
                // Keep typed text intact, and let Enter finish this conversation.
                if (root.fingerprintExpired && root.fingerprintAvailable
                        && !root.submitted && !root.queuedResponse.length
                        && root.available && !root.accepted) {
                    root.fingerprintExpired = false;
                    root.fingerprintRestarting = true;
                    root.fingerprintState = "ready";
                    root.message = "";
                    client.begin(root.selectedUser.username);
                }
                return;
            }
            // pam_fprintd returns device failures without a PAM conversation
            // message. A root-owned pam_echo marker makes that failure visible.
            if (text === "GREETER_FINGERPRINT_ERROR") {
                if (!root.fingerprintTimedOut) {
                    root.fingerprintExpired = false;
                    root.message = Strings.greeterFingerprintError;
                    root.fingerprintState = "failure";
                }
                root.fingerprintTimedOut = false;
                return;
            }
            if (/verification timed out|przekroczono.*czas|przekroczy.*(?:czas|limit)|upłynął.*czas/i.test(text)) {
                root.fingerprintTimedOut = true;
                root.fingerprintExpired = true;
                return;
            }
            if (echoResponse !== root.echoResponse) root.clearPassword();
            root.echoResponse = echoResponse;
            if (responseRequired) {
                root.submitted = false;
                // Nonstandard PAM challenges remain answerable, without logging
                // or assuming that the first secret is the only possible one.
                if (!/^(?:password|hasło)\s*:?$/i.test(text))
                    root.message = Strings.authenticationText(prompt);
                if (echoResponse) root.queuedResponse = "";
                if (root.queuedResponse.length && !root.usersOpen && !echoResponse) {
                    const response = root.queuedResponse;
                    root.queuedResponse = "";
                    root.submitted = true;
                    client.respond(response);
                }
            } else if (/finger|palec|palca|odcisk/i.test(prompt)) {
                root.fingerprintTimedOut = false;
                root.fingerprintExpired = false;
                root.fingerprintAvailable = true;
                root.fingerprintState = error || root.message === Strings.greeterFingerprintError ? "failure" : "ready";
                if (error) root.message = Strings.lockFingerprintFailed;
            } else if (error) {
                root.message = Strings.authenticationText(prompt);
            }
        }
        onAuthFailure: {
            root.queuedResponse = "";
            root.submitted = root.accepted = false;
            root.clearPassword();
            root.message = Strings.greeterFailed;
            root.fingerprintState = "failure";
        }
        onTransportError: {
            root.queuedResponse = "";
            root.submitted = root.accepted = false;
            successDelay.stop();
            root.clearPassword();
            root.message = Strings.greeterUnavailable;
            recoveryDelay.restart();
        }
        onReadyToLaunch: {
            root.queuedResponse = "";
            root.clearPassword();
            if (root.usersOpen || !root.selectedUser || client.user !== root.selectedUser.username) {
                client.cancel();
                return;
            }
            root.submitted = false;
            root.accepted = true;
            root.message = "";
            root.fingerprintState = "success";
            successDelay.start();
        }
        onLaunched: root.sessionLaunched()
    }
    Timer {
        id: recoveryDelay
        interval: 5000
        onTriggered: root.restartRequested()
    }
    Timer {
        id: successDelay
        interval: Motion.elaborate
        onTriggered: {
            if (root.accepted && !root.usersOpen && root.selectedUser
                    && root.selectedUser.username === client.user) client.launch();
        }
    }
    Connections {
        target: GreeterConfig
        function onReadyChanged() {
            if (!GreeterConfig.ready) return;
            const user = GreeterConfig.users.find(user => user.username === GreeterConfig.defaultUser)
                || GreeterConfig.users[0];
            if (user) root.chooseUser(user);
            else root.message = Strings.greeterNoUsers;
        }
    }
    Component.onDestruction: { queuedResponse = ""; clearPassword(); client.cancel(); }
}
