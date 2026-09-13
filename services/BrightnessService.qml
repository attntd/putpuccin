pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.core

Singleton {
    id: root

    property string state: "loading"
    property string deviceName: ""
    property real percentage: 0
    property real targetPercentage: 0
    property int rawBrightness: 0
    property int maximumBrightness: 0
    readonly property real sliderPercentage: commandPending ? targetPercentage : percentage
    property string errorMessage: ""
    property bool commandPending: false
    property int watcherFailures: 0
    property bool eventWatcherDesired: true

    readonly property bool available: state === "ready"
    readonly property int minimumVisibleRaw: Math.max(1, Math.round(maximumBrightness / 100))
    readonly property int targetRawBrightness: targetPercentage === 0 ? 0
        : Math.max(1, Math.round(maximumBrightness * targetPercentage / 100))

    function refresh() {
        if (readProcess.running || commandPending)
            return;
        readTimeout.restart();
        readProcess.running = true;
    }

    function setPercentage(value) {
        if (!root.available || !Number.isFinite(value))
            return;
        root.targetPercentage = value <= 0 ? 0 : Math.max(1, Math.min(100, value));
        commandTimeout.restart();
        if (commandProcess.running) {
            commandProcess.write(root.targetPercentage + "\n");
        } else {
            root.startTransition();
        }
    }

    function startTransition() {
        if (commandProcess.running) {
            commandProcess.write(root.targetPercentage + "\n");
            return;
        }
        root.commandPending = true;
        commandTimeout.restart();
        commandProcess.exec([Quickshell.shellPath("scripts/brightness-transition"), root.deviceName,
            String(root.targetPercentage), String(Motion.standard)]);
    }

    function adjust(delta) {
        if (!root.available || !Number.isFinite(delta) || delta === 0)
            return;
        const current = root.sliderPercentage;
        // Reach the visible minimum first, then turn off on the next step.
        // Compare raw levels after settling: 1% may round above 1 on hardware.
        const atMinimum = (root.commandPending ? root.targetRawBrightness : root.rawBrightness)
            <= root.minimumVisibleRaw;
        if (delta < 0)
            root.setPercentage(atMinimum ? 0 : Math.max(1, current + delta));
        else
            root.setPercentage(current === 0 ? 1 : current + delta);
    }

    Process {
        id: readProcess
        command: ["brightnessctl", "--machine-readable", "info"]
        stdout: StdioCollector {
            id: readOutput
        }
        stderr: StdioCollector {
            id: readError
        }
        onExited: exitCode => {
            readTimeout.stop();
            if (root.commandPending)
                return;
            if (exitCode !== 0) {
                root.state = "unavailable";
                root.errorMessage = readError.text.trim() || "Nie znaleziono urządzenia podświetlenia.";
                return;
            }
            const fields = readOutput.text.trim().split(",");
            root.deviceName = fields.length > 0 ? fields[0] : "";
            root.rawBrightness = Number(fields[2]) || 0;
            root.maximumBrightness = Number(fields[4]) || 0;
            if (root.maximumBrightness <= 0 || !/^[A-Za-z0-9_.:-]+$/.test(root.deviceName)) {
                root.state = "error";
                root.errorMessage = "Nieprawidłowy zakres podświetlenia.";
                return;
            }
            root.percentage = root.rawBrightness * 100 / root.maximumBrightness;
            root.targetPercentage = root.percentage;
            root.errorMessage = "";
            root.state = "ready";
        }
    }

    Timer {
        id: readTimeout
        interval: 2000
        onTriggered: {
            if (readProcess.running)
                readProcess.running = false;
            root.state = "error";
            root.errorMessage = "Odczyt jasności przekroczył limit czasu.";
        }
    }

    Process {
        id: commandProcess
        stdinEnabled: true
        stdout: SplitParser {
            onRead: data => {
                try {
                    const sample = JSON.parse(data);
                    if (Number.isInteger(sample.raw) && sample.raw >= 0 && sample.raw <= root.maximumBrightness
                            && sample.maximum === root.maximumBrightness) {
                        root.rawBrightness = sample.raw;
                        root.percentage = sample.raw * 100 / sample.maximum;
                        commandTimeout.restart();
                    }
                } catch (error) {}
            }
        }
        stderr: StdioCollector {
            id: commandError
        }
        onExited: exitCode => {
            commandTimeout.stop();
            if (root.state === "error") {
                root.commandPending = false;
                return;
            }
            if (exitCode !== 0) {
                root.commandPending = false;
                root.state = "error";
                root.errorMessage = commandError.text.trim() || "Nie udało się zmienić jasności.";
                return;
            }
            // A request can arrive between the helper's final read and exit.
            if (root.rawBrightness !== root.targetRawBrightness) {
                Qt.callLater(() => root.startTransition());
                return;
            }
            root.commandPending = false;
            root.refresh();
        }
    }

    Timer {
        id: commandTimeout
        interval: 3000
        onTriggered: {
            commandProcess.running = false;
            root.commandPending = false;
            root.state = "error";
            root.errorMessage = "Zmiana jasności przekroczyła limit czasu.";
        }
    }

    IpcHandler {
        target: "brightness"
        function adjust(delta: real): void { root.adjust(delta); }
        function set(value: real): void { root.setPercentage(value); }
    }

    Timer {
        id: refreshDebounce
        interval: Motion.fast
        onTriggered: root.refresh()
    }

    Process {
        id: eventWatcher
        running: root.eventWatcherDesired
        command: ["udevadm", "monitor", "--udev", "--subsystem-match=backlight"]
        stdout: SplitParser {
            onRead: data => refreshDebounce.restart()
        }
        stderr: SplitParser {}
        onStarted: watcherStable.restart()
        onExited: exitCode => {
            watcherStable.stop();
            root.eventWatcherDesired = false;
            root.watcherFailures++;
            if (root.watcherFailures <= 5)
                watcherRestart.restart();
        }
    }

    Timer {
        id: watcherStable
        interval: 10000
        onTriggered: root.watcherFailures = 0
    }

    Timer {
        id: watcherRestart
        interval: Math.min(30000, 1000 * Math.pow(2, Math.max(0, root.watcherFailures - 1)))
        onTriggered: root.eventWatcherDesired = true
    }

    Component.onCompleted: root.refresh()
}
