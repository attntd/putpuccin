import QtQuick
import QtQuick.Controls
import QtTest
import Quickshell
import qs.core
import qs.services

TestCase {
    id: checks
    required property var panelLoader
    required property var testWindow
    property bool recordingFrames: false
    property var frameTimes: []
    when: false

    Connections {
        target: checks.testWindow
        function onFrameSwapped() {
            if (checks.recordingFrames) checks.frameTimes.push(Date.now());
        }
    }

    function check(ok, message) { if (!ok) throw new Error(message); }
    function find(name, item) {
        item = item || panelLoader.item;
        if (item.objectName === name) return item;
        for (const child of item.children || []) {
            const found = find(name, child);
            if (found) return found;
        }
        return null;
    }
    function settle() { wait(260); check(waitForPolish(testWindow, 500), "Audio layout did not settle"); }
    function click(item) { mouseClick(item, item.width / 2, item.height / 2); }
    function panelY(item) { return item.mapToItem(panelLoader.item, 0, 0).y; }
    function hold(button, control) {
        const muted = control.muted;
        const level = control.level;
        mousePress(button, button.width / 2, button.height / 2);
        wait(850);
        check(!control.expanded, "Device list opened before one second");
        wait(220);
        check(control.expanded, "One-second hold did not open devices");
        mouseRelease(button, button.width / 2, button.height / 2);
        settle();
        check(control.muted === muted && control.level === level, "Holding the icon also changed mute or volume");
    }
    function close(control, button) {
        keyClick(Qt.Key_Escape);
        settle();
        check(!control.expanded && button.activeFocus, "Escape did not restore icon focus");
    }
    function screenshot(name) {
        let saved = false;
        panelLoader.item.grabToImage(result => {
            saved = result.saveToFile(Quickshell.env("QS_CAFFEINATE_PROOF") + "/audio-" + name + ".png");
        });
        tryVerify(() => saved, 1000);
        check(saved, "Audio screenshot failed");
    }
    function run(reduced) {
        Settings.reducedMotion = reduced;
        const output = find("quickOutputAudio");
        const input = find("quickInputAudio");
        const volume = find("quickVolume");
        const microphone = find("quickMicrophoneVolume");
        const inputButton = find("quickMicrophone");
        settle();
        check(find("quickMicrophone").text === "", "Microphone tile still exists");
        check(panelY(microphone) > panelY(volume) && panelY(find("quickBrightness")) > panelY(microphone),
            "Microphone is not between output volume and brightness");
        check(volume.width === microphone.width && volume.from === 0 && volume.to === 1
            && microphone.from === 0 && microphone.to === 1, "Slider geometry or range differs");
        check(find("quickOutputDevicesLoader").item === null && find("quickInputDevicesLoader").item === null,
            "Closed device lists were instantiated");
        const baseHeight = panelLoader.item.implicitHeight;

        for (const [control, slider, prefix, levelProperty] of [
            [output, volume, "quickOutput", "volume"],
            [input, microphone, "quickInput", "sourceVolume"]
        ]) {
            const button = find(control.input ? "quickMicrophone" : "quickMute");
            const percentage = slider.parent.children.find(child => typeof child.text === "string" && child.text.endsWith("%"));
            const muteProperty = control.input ? "sourceMuted" : "muted";
            const initialLevel = AudioService[levelProperty];
            // Hardware mute keys update the service independently of this panel.
            AudioService[muteProperty] = true;
            check(slider.value === 0 && percentage.text === "0%", "External mute did not reset the slider and percentage");
            check(AudioService[levelProperty] === initialLevel, "Displaying mute overwrote the saved audio level");
            screenshot(prefix + "-muted");
            AudioService[muteProperty] = false;
            check(slider.value === initialLevel, "External unmute did not restore the saved audio level");
            AudioService[muteProperty] = true;
            AudioService[levelProperty] = 0.72;
            check(slider.value === 0 && percentage.text === "0%", "External level change exposed a muted slider");
            AudioService[muteProperty] = false;
            check(slider.value === 0.72 && percentage.text === "72%", "Unmute did not show the latest audio level");
            AudioService[levelProperty] = initialLevel;

            mouseMove(slider, slider.width / 2, slider.height / 2);
            wait(1100);
            check(!slider.ToolTip.visible && !control.expanded, "Hover displayed a slider tooltip or devices");
            mousePress(slider, slider.width / 4, slider.height / 2);
            wait(200);
            mouseRelease(slider, slider.width / 4, slider.height / 2);
            wait(900);
            check(!control.expanded, "Short press opened a device list after release");
            check(AudioService[levelProperty] < 0.35, "Click did not update the audio level");

            mousePress(slider, slider.width / 4, slider.height / 2);
            mouseMove(slider, slider.width * 0.8, slider.height / 2, 30);
            wait(1100);
            check(!control.expanded, "Dragging opened a device list");
            mouseRelease(slider, slider.width * 0.8, slider.height / 2);
            check(AudioService[levelProperty] > 0.7, "Dragging stopped updating the audio level");

            mousePress(slider, slider.width / 2, slider.height / 2);
            wait(1100);
            check(!control.expanded, "Holding the slider opened devices");
            mouseRelease(slider, slider.width / 2, slider.height / 2);

            const muted = control.muted;
            click(button);
            wait(1100);
            check(control.muted !== muted && !control.expanded, "Short icon click did not only toggle mute");
            check(slider.value === 0 && percentage.text === "0%", "Icon mute did not reset the slider and percentage");
            click(button);
            check(control.muted === muted, "Second icon click did not restore mute");
            check(slider.value === AudioService[levelProperty], "Icon unmute did not restore the saved audio level");

            mousePress(button, button.width / 2, button.height / 2);
            mouseMove(button, button.width + 20, button.height / 2, 30);
            wait(1100);
            mouseRelease(button, button.width + 20, button.height / 2);
            check(!control.expanded && control.muted === muted, "Leaving the icon did not cancel the gesture");

            hold(button, control);
            const list = find(prefix + "Devices");
            check(panelY(list) > panelY(slider) + slider.height, "Devices are not below their slider");
            check(list.width === control.width && panelLoader.item.implicitHeight > baseHeight,
                "Device list did not expand the panel");
            check(list.height <= 3 * Metrics.popupRowHeight + 2 * Metrics.space4,
                "Device list is not bounded");
            screenshot(prefix + (reduced ? "-reduced" : ""));
            click(find(prefix + "Device-1"));
            settle();
            check(control.selectedDevice === control.devices[1] && !control.expanded,
                "Mouse selection did not select the device and close the list");
            check(find(prefix + "DevicesLoader").item === null, "Selection retained the hidden device list");

            slider.forceActiveFocus(Qt.TabFocusReason);
            const level = AudioService[levelProperty];
            keyClick(Qt.Key_Left);
            check(AudioService[levelProperty] < level, "Keyboard volume adjustment failed");
            button.forceActiveFocus(Qt.TabFocusReason);
            keyClick(Qt.Key_Down);
            settle();
            const keyboardList = find(prefix + "Devices");
            check(keyboardList.activeFocus && keyboardList.currentIndex === 1, "Selected device did not receive focus");
            if (control.devices.length > 3) {
                keyClick(Qt.Key_Down);
                keyClick(Qt.Key_Down);
                settle();
                check(keyboardList.currentIndex === 3 && keyboardList.contentY > 0,
                    "Keyboard did not scroll to a device below the visible rows");
                keyClick(Qt.Key_Space);
                settle();
                check(control.selectedDevice === control.devices[3] && !control.expanded,
                    "Space did not select the device below the visible rows");
                keyClick(Qt.Key_Down);
                settle();
                check(find(prefix + "Devices").currentIndex === 3, "Reopened list lost the scrolled selection");
                keyClick(Qt.Key_Up);
                keyClick(Qt.Key_Up);
            }
            keyClick(Qt.Key_Up);
            keyClick(Qt.Key_Return);
            settle();
            check(control.selectedDevice === control.devices[0] && button.activeFocus && !control.expanded,
                "Keyboard device selection failed");
            keyClick(Qt.Key_Down);
            settle();
            close(control, button);
            keyClick(Qt.Key_Return);
            settle();
            check(control.muted === muted && control.expanded, "Enter must open devices without toggling mute");
            close(control, button);
            keyClick(Qt.Key_Space);
            check(control.muted !== muted && !control.expanded, "Space must toggle mute without opening devices");
            keyClick(Qt.Key_Space);
            check(control.muted === muted, "Space on icon did not toggle mute");
        }

        output.openDevices(true); settle();
        input.openDevices(true); settle();
        check(!output.expanded && input.expanded, "Both device lists remained open");
        check(find("quickOutputDevicesLoader").item === null, "Previous device list remained loaded");
        panelLoader.item.openCaffeinate(true); settle();
        check(!input.expanded, "Caffeinate did not close the audio list");
        input.openDevices(true); settle();
        check(!panelLoader.item.caffeinateExpanded, "Audio did not close Caffeinate");

        const devices = AudioService.sources;
        AudioService.sources = [];
        AudioService.source = null;
        AudioService.sourceAvailable = false;
        settle();
        check(find("quickInputDevices").count === 0 && !microphone.enabled,
            "Disconnected input left stale devices or an enabled slider");
        AudioService.sources = devices;
        AudioService.source = devices[0];
        AudioService.sourceAvailable = true;
        settle();
        check(find("quickInputDevices").count === devices.length && microphone.enabled,
            "Input device reconnect failed");
        close(input, inputButton);

        mousePress(inputButton, inputButton.width / 2, inputButton.height / 2);
        wait(200);
        panelLoader.item.visible = false;
        wait(1100);
        mouseRelease(inputButton, inputButton.width / 2, inputButton.height / 2);
        panelLoader.item.visible = true;
        settle();
        check(!input.expanded, "Hidden panel completed a pending hold");
        check(panelLoader.item.implicitHeight === baseHeight, "Collapsed audio retained extra height");
        hold(inputButton, input);
        close(input, inputButton);
        screenshot("collapsed");

        frameTimes = [];
        recordingFrames = true;
        output.openDevices(false);
        const progress = [];
        for (let frame = 0; frame < 16; frame++) {
            wait(16);
            progress.push(find("quickOutputReveal").progress);
        }
        recordingFrames = false;
        check(progress[progress.length - 1] === 1
            && progress.some(value => value > 0 && value < 1)
            && progress.every((value, index) => index === 0 || value >= progress[index - 1]),
            "Audio reveal animation skipped intermediate frames or moved backwards");
        const intervals = frameTimes.slice(1).map((value, index) => value - frameTimes[index]);
        output.closeDevices(); settle();
        const closed = SurfaceManager.closed;
        keyClick(Qt.Key_Escape);
        check(SurfaceManager.closed === closed + 1, "Escape did not close the main panel");
        return {passed: true, reducedMotion: reduced, revealProgress: progress, frameIntervalsMs: intervals};
    }
    function cycle() {
        panelLoader.active = false; settle();
        check(panelLoader.item === null, "Quick menu was not destroyed");
        panelLoader.active = true; settle();
        for (const prefix of ["quickOutput", "quickInput"]) {
            const control = find(prefix + "Audio");
            check(!control.expanded && find(prefix + "DevicesLoader").item === null,
                "New panel restored temporary device state");
            control.openDevices(true); settle();
            check(find(prefix + "DevicesLoader").item !== null, "Device list did not load");
            control.closeDevices(); settle();
            check(find(prefix + "DevicesLoader").item === null, "Device list survived its closing animation");
        }
        return {passed: true};
    }
}
