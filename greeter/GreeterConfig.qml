pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root
    property var users: []
    property string defaultUser: ""
    property url wallpaperSource
    property bool ready: false
    property string error: ""

    Process {
        id: enumerateUsers
        command: [Quickshell.shellPath("users")]
        running: true
        stdout: StdioCollector { id: output }
        stderr: StdioCollector {}
        onExited: code => {
            deadline.stop();
            if (code !== 0) { root.error = "Nie można odczytać konfiguracji logowania."; return; }
            try {
                const data = JSON.parse(output.text);
                if (data.version !== 1 || !Array.isArray(data.users) || data.users.length > 256)
                    throw new Error("Invalid greeter configuration");
                root.users = data.users.filter(user => typeof user.username === "string"
                    && /^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,63}$/.test(user.username)
                    && user.username !== "root" && user.username !== "greeter");
                root.defaultUser = String(data.defaultUser || "");
                root.wallpaperSource = Qt.resolvedUrl("assets/wallpaper");
                root.ready = true;
            } catch (error) { root.error = "Nie można odczytać konfiguracji logowania."; }
        }
    }
    Timer {
        id: deadline
        interval: 3000
        running: true
        onTriggered: {
            enumerateUsers.running = false;
            root.error = "Nie można odczytać listy użytkowników.";
        }
    }
}
