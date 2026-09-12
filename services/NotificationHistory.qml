import QtQuick
import Quickshell
import Quickshell.Io

Scope {
    id: root
    readonly property string path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state")
        + "/quickshell-de/notifications.json"
    property bool ready: false
    property bool writable: false
    property string errorMessage: ""
    property var pending: null
    signal loaded(var data)

    function schedule(data) {
        pending = data;
        if (writable)
            debounce.restart();
    }

    function flush() {
        if (writable && pending !== null) {
            file.setText(JSON.stringify(pending));
            pending = null;
        }
    }

    function finish(data) {
        if (ready)
            return;
        ready = true;
        loaded(data);
    }

    // Python is needed only for mkdir/chmod and corrupt-file quarantine, which
    // FileView cannot do. Once per generation, 3 s deadline, cancelled on unload;
    // failure leaves a working in-memory server and a visible error in the panel.
    Process {
        id: initialize
        command: ["sh", Qt.resolvedUrl("../scripts/notification-state").toString().replace("file://", ""), root.path]
        running: true
        stdout: StdioCollector { id: output }
        stderr: StdioCollector { id: failure }
        onExited: code => {
            deadline.stop();
            if (code !== 0) {
                root.errorMessage = "Nie można zapisać historii powiadomień: " + failure.text.trim();
                root.finish({});
                return;
            }
            try {
                if (JSON.parse(output.text).recovered)
                    root.errorMessage = "Uszkodzoną historię zachowano w kopii .corrupt. Utworzono nową.";
            } catch (error) {}
            root.writable = true;
            file.path = root.path;
        }
    }
    Timer {
        id: deadline
        running: true
        interval: 3000
        onTriggered: {
            initialize.running = false;
            root.errorMessage = "Przekroczono czas otwierania historii powiadomień.";
            root.finish({});
        }
    }
    FileView {
        id: file
        printErrors: false
        watchChanges: false
        atomicWrites: true
        onLoaded: {
            try { root.finish(JSON.parse(text())); }
            catch (error) {
                root.errorMessage = "Nie można odczytać historii powiadomień.";
                root.finish({});
            }
        }
        onLoadFailed: error => {
            root.errorMessage = "Nie można odczytać historii powiadomień: " + error;
            root.finish({});
        }
        onSaveFailed: error => root.errorMessage = "Nie można zapisać historii powiadomień: " + error
    }
    Timer { id: debounce; interval: 250; onTriggered: root.flush() }
    Component.onDestruction: {
        root.flush();
        file.waitForJob();
    }
}
