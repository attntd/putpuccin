//@ pragma ShellId caffeinate-test
import QtQuick
import QtQuick.Window
import QtTest
import Quickshell
import Quickshell.Io
import qs.core
import qs.services
import qs.popups

ShellRoot {
    QtObject {
        id: osd
        property var item: null
        Component.onCompleted: {
            if (Quickshell.env("QS_QUICK_TILES_ONLY") === "1" && Quickshell.env("QS_CAFFEINATE_WAYLAND"))
                item = Qt.createComponent("modules/osd/LevelOsd.qml").createObject(osd, {screenName: "caffeinate-test"});
        }
    }
    Window {
        id: window
        visible: true
        width: 450
        height: 680
        color: Theme.base
        Loader {
            id: loader
            x: 20
            y: 20
            width: 410
            sourceComponent: QuickSettingsPopup { screenName: "caffeinate-test" }
        }
        QuickAudioChecks {
            id: audioTests
            panelLoader: loader
            testWindow: window
        }
        TestCase {
            id: tests
            when: false
            function check(ok, message) { if (!ok) throw new Error(message); }
            function find(item, name) {
                if (item.objectName === name) return item;
                for (const child of item.children || []) {
                    const found = find(child, name);
                    if (found) return found;
                }
                return null;
            }
            function tile() { return find(loader.item, "quickCaffeinate"); }
            function click(item) { mouseClick(item, item.width/2, item.height/2); }
            function settle() { wait(250); check(waitForPolish(window, 500), "Layout did not settle"); }
            function textItem(item, text) {
                if (item.visible && item.text === text && item.font) return item;
                for (const child of item.children || []) {
                    const found = textItem(child, text);
                    if (found) return found;
                }
                return null;
            }
            function contentGeometry(button) {
                const icon = textItem(button.contentItem, button.glyph);
                const label = textItem(button.contentItem, button.text);
                check(!!icon && (button.text.length === 0 || !!label), "Missing tile content");
                function rect(item) {
                    const point = item.mapToItem(loader.item, 0, 0);
                    return [point.x, point.y, item.width, item.height];
                }
                return {tile: rect(button), icon: rect(icon), label: label ? rect(label) : null};
            }
            function saveItem(item, name) {
                let saved = false;
                check(item.grabToImage(result => {
                    saved = result.saveToFile(Quickshell.env("QS_CAFFEINATE_PROOF") + "/" + name + ".png");
                }), "Could not capture " + name);
                tryVerify(() => saved, 1000);
                check(saved, "Could not save " + name);
            }
            function tiles() {
                const mic = find(loader.item, "quickMicrophone");
                const dnd = find(loader.item, "quickDnd");
                const volume = find(loader.item, "quickMute");
                check(!Quickshell.env("QS_CAFFEINATE_WAYLAND") || !!osd.item, "OSD did not load");
                const panel = osd.item ? find(osd.item.contentItem, "levelOsdPanel") : null;
                const osdIcon = panel ? panel.children[0].children[0] : null;
                const osdGlyph = osdIcon ? (osdIcon.text !== undefined ? osdIcon : osdIcon.children[0]) : null;
                const osdTrack = panel ? panel.children[0].children[1] : null;
                function osdGeometry() {
                    if (!panel) return null;
                    function rect(item) { return [item.x, item.y, item.width, item.height]; }
                    return {window: [osd.item.width, osd.item.height], panel: rect(panel),
                        icon: rect(osdIcon), track: rect(osdTrack)};
                }
                function snapshot(name) {
                    saveItem(loader.item, "tiles-" + name);
                    for (const [button, prefix] of [[mic, "microphone"], [dnd, "bell"], [volume, "volume"]])
                        saveItem(textItem(button.contentItem, button.glyph), prefix + "-" + name);
                    if (panel) {
                        saveItem(osdGlyph, "osd-volume-" + name);
                        saveItem(panel, "osd-" + name);
                    }
                }
                AudioService.sourceMuted = false;
                NotificationService.dnd = false;
                AudioService.muted = false;
                OsdService.show("volume", AudioService.volume, false);
                settle();
                const before = [contentGeometry(mic), contentGeometry(dnd), contentGeometry(volume), osdGeometry()];
                const iconHeights = {microphone: before[0].icon[3], bell: before[1].icon[3],
                    volume: before[2].icon[3]};
                if (panel) iconHeights["osd-volume"] = osdGlyph.height;
                snapshot("on");
                const samples = [];
                for (let cycle = 0; cycle < 20; cycle++) {
                    click(mic); settle();
                    if (panel) {
                        check(osd.item.visible && OsdService.kind === "microphone"
                            && OsdService.muted === AudioService.sourceMuted, "OSD missed microphone mute change");
                        check(osdGlyph.text === Icons.microphone
                            && osdGlyph.children[0].visible === AudioService.sourceMuted,
                            "Microphone OSD has the wrong icon or slash");
                        check(JSON.stringify(osdGeometry()) === JSON.stringify(before[3]), "Microphone changed OSD geometry");
                        if (cycle < 2) {
                            iconHeights["osd-microphone"] = osdGlyph.height;
                            const state = cycle === 0 ? "off" : "on";
                            saveItem(osdGlyph, "osd-microphone-" + state);
                            saveItem(panel, "osd-microphone-panel-" + state);
                        }
                    }
                    click(dnd); click(volume); settle();
                    check(waitForPolish(window, 500), "Tile layout did not settle");
                    check(AudioService.sourceMuted === (cycle % 2 === 0)
                        && NotificationService.dnd === (cycle % 2 === 0)
                        && AudioService.muted === (cycle % 2 === 0), "Toggle did not reach the service");
                    if (panel) check(osd.item.visible && OsdService.muted === AudioService.muted, "OSD missed mute change");
                    samples.push([contentGeometry(mic), contentGeometry(dnd), contentGeometry(volume), osdGeometry()]);
                    if (cycle === 0) snapshot("off");
                    OsdService.shown = false;
                    if (panel) tryVerify(() => !osd.item.visible, 1000);
                }
                return {passed: samples.every(sample => JSON.stringify(sample) === JSON.stringify(before)),
                    cycles: samples.length, iconHeights: iconHeights, beforeGeometry: before, afterGeometry: samples[0]};
            }
            function microphoneOsd() {
                check(!!osd.item, "Microphone OSD test needs private Wayland");
                const panel = find(osd.item.contentItem, "levelOsdPanel");
                const track = panel.children[0].children[1];
                const savedOutputAvailable = AudioService.available;
                OsdService.shown = false;
                AudioService.available = false;
                AudioService.sourceAvailable = false;
                AudioService.sourceMuted = true;
                AudioService.sourceVolume = 0.7;
                settle();
                check(!OsdService.shown, "Unavailable microphone showed OSD");
                AudioService.sourceAvailable = true;
                AudioService.sourceMuted = false;
                AudioService.sourceVolume = 0.6;
                settle();
                check(!OsdService.shown, "Initial microphone state showed OSD after reconnect");

                // Hardware keys change the service without clicking quick menu.
                AudioService.sourceMuted = true;
                check(OsdService.shown && OsdService.kind === "microphone" && OsdService.muted,
                    "External microphone mute did not show OSD without an output device");
                const fade = [];
                for (let frame = 0; frame < 16; frame++) { wait(16); fade.push(panel.opacity); }
                check(fade[fade.length - 1] === 1 && fade.some(value => value > 0 && value < 1)
                    && fade.every((value, index) => index === 0 || value >= fade[index - 1]),
                    "Microphone OSD fade skipped intermediate frames or moved backwards");
                check(track.children[0].width === 0 && AudioService.sourceVolume === 0.6,
                    "Muted OSD retained its fill or changed the microphone level");
                wait(600);
                AudioService.sourceMuted = false;
                settle();
                check(!OsdService.muted && OsdService.value === 0.6
                    && Math.abs(track.children[0].width - track.width * 0.6) < 0.01,
                    "External microphone unmute did not restore the displayed level");
                wait(500);
                check(OsdService.shown && osd.item.visible, "Unmute did not restart the OSD timeout");
                tryVerify(() => !OsdService.shown && !osd.item.visible, 1200);
                check(!OsdService.shown && !osd.item.visible, "Microphone OSD did not hide after its timeout");

                AudioService.sourceVolume = 0.72;
                check(OsdService.shown && OsdService.kind === "microphone" && OsdService.value === 0.72,
                    "Microphone level change did not show OSD");
                AudioService.available = savedOutputAvailable;
                settle();
                AudioService.muted = true;
                check(OsdService.kind === "volume" && OsdService.muted, "Speaker did not replace microphone OSD");
                AudioService.muted = false;
                AudioService.sourceVolume = 0.6;
                OsdService.shown = false;
                settle();
                return {passed: true, fadeProgress: fade};
            }
            function smoke(reduced) {
                Settings.reducedMotion = reduced;
                CaffeinateService.setEnabled(false);
                settle();
                click(tile()); settle();
                click(find(loader.item, "caffeinateMode-presentation")); settle();
                check(CaffeinateService.active, "Mode did not enable");
                loader.active = false; settle();
                check(loader.item === null && CaffeinateService.active, "Panel lifecycle changed inhibitor");
                loader.active = true; settle();
                click(tile()); settle();
                click(find(loader.item, "caffeinateMode-off")); settle();
                check(!CaffeinateService.active, "Tile did not disable");
                return {passed: true};
            }
            function openClick() {
                mouseMove(window, 430, 660);
                wait(200);
                mouseMove(tile(), tile().width/2, tile().height/2);
                wait(90);
                check(!loader.item.caffeinateExpanded, "Hover opened before 150 ms");
                wait(90);
                check(!loader.item.caffeinateExpanded, "Hover opened the menu");
                click(tile());
                check(loader.item.caffeinateExpanded, "Click did not open the menu");
                settle();
            }
            function select(mode) {
                click(find(loader.item, "caffeinateMode-" + mode));
                settle();
                check(CaffeinateService.mode === mode && CaffeinateService.active, "Wrong mode: " + mode);
                check(!loader.item.caffeinateExpanded, "Selection did not close menu");
                check(tile().glyph === Icons.coffee && tile().accent, "Tile icon/accent changed incorrectly");
                check(tile().text === CaffeinateService.label && tile().text !== Strings.caffeinate, "Tile lacks mode label");
            }
            function run(reduced) {
                Settings.reducedMotion = reduced;
                CaffeinateService.setEnabled(false);
                settle();
                mouseMove(window, 430, 660);
                wait(200);
                const baseHeight = loader.item.implicitHeight;
                mouseMove(tile(), tile().width/2, tile().height/2);
                wait(50);
                mouseMove(window, 430, 660);
                wait(200);
                check(!loader.item.caffeinateExpanded, "A short hover opened the menu");
                openClick();
                check(!CaffeinateService.active, "Hover activated a mode");
                const list = find(loader.item, "caffeinateModes");
                check(list.width === loader.item.width - 2*loader.item.padding, "List does not fill the panel");
                const listPosition = list.mapToItem(loader.item, 0, 0);
                const tilePosition = tile().mapToItem(loader.item, 0, 0);
                check(listPosition.y >= tilePosition.y + tile().height, "List overlaps tile");
                check(loader.item.implicitHeight > baseHeight, "List did not expand panel");
                mouseMove(loader.item, tilePosition.x+20, tilePosition.y+tile().height+5);
                wait(50);
                const first = find(loader.item, "caffeinateMode-background");
                mouseMove(first, 30, first.height/2);
                wait(200);
                check(loader.item.caffeinateExpanded, "Crossing the gap closed the menu");
                select("background");
                check(CaffeinateService.preventLock && !CaffeinateService.preventDisplaySleep, "Background policy incorrect");
                wait(200);
                check(!loader.item.caffeinateExpanded, "Menu reopened after selection");
                openClick(); select("presentation");
                check(CaffeinateService.preventLock && CaffeinateService.preventDisplaySleep, "Presentation policy incorrect");
                openClick(); select("secure-background");
                check(!CaffeinateService.preventLock && !CaffeinateService.preventDisplaySleep, "Secure policy incorrect");
                openClick(); select("secure-background");
                mouseMove(window, 430, 660);
                loader.active = false; settle();
                check(loader.item === null && CaffeinateService.active, "Panel destruction released active mode");
                loader.active = true; settle();
                check(!loader.item.caffeinateExpanded && tile().text === Strings.caffeinateSecureBackgroundShort, "Panel did not restore mode");
                mouseMove(window, 430, 660);
                tile().forceActiveFocus();
                keyClick(Qt.Key_Down);
                settle();
                check(find(loader.item, "caffeinateMode-secure-background").activeFocus, "Keyboard lost selected mode focus");
                keyClick(Qt.Key_Down);
                keyClick(Qt.Key_Down);
                keyClick(Qt.Key_Return);
                settle();
                check(CaffeinateService.mode === "background" && tile().activeFocus, "Keyboard selection failed");
                keyClick(Qt.Key_Down); settle();
                keyClick(Qt.Key_Escape); settle();
                check(!loader.item.caffeinateExpanded && tile().activeFocus, "Escape did not return focus");
                click(tile()); settle();
                click(find(loader.item, "caffeinateMode-off")); settle();
                check(!CaffeinateService.active && tile().text === Strings.caffeinate, "Main tile did not disable");
                check(tile().glyph === Icons.coffee && !tile().accent, "Disabled icon/accent incorrect");
                mouseMove(window, 430, 660); wait(200);
                check(loader.item.implicitHeight === baseHeight, "Hidden list retained extra height");
                click(tile()); settle();
                check(loader.item.caffeinateExpanded && !CaffeinateService.active, "Inactive click should only choose a mode");
                keyClick(Qt.Key_Escape); settle();
                const closed = SurfaceManager.closed;
                keyClick(Qt.Key_Escape);
                check(SurfaceManager.closed === closed + 1, "Second Escape did not close main panel");
                return {passed: true};
            }
            function keyboard() {
                loader.item.closeCaffeinate();
                find(loader.item, "quickOutputAudio").closeDevices();
                find(loader.item, "quickInputAudio").closeDevices();
                settle();
                loader.item.focusDefaultControl();
                check(find(loader.item, "quickWifi").activeFocus, "Default focus is not Wi-Fi");
                const wifi = find(loader.item, "quickWifi");
                const wifiGeometry = JSON.stringify(contentGeometry(wifi));
                keyClick(Qt.Key_Space); settle();
                check(!NetworkService.wifiEnabled && wifi.glyph === Icons.wifi && wifi.glyphSlashed,
                    "Disabled Wi-Fi must preserve the glyph and use the toolbar slash");
                check(JSON.stringify(contentGeometry(wifi)) === wifiGeometry, "Disabled Wi-Fi moved the icon or label");
                keyClick(Qt.Key_Space); settle();
                check(NetworkService.wifiEnabled && !wifi.glyphSlashed, "Wi-Fi did not toggle back");
                NetworkService.wiredDevice = {connected:true}; settle();
                check(wifi.text === Strings.ethernet && wifi.glyph === Icons.ethernet && wifi.accent && !wifi.glyphSlashed,
                    "Ethernet must take precedence over Wi-Fi");
                keyClick(Qt.Key_Return);
                check(NetworkService.wifiEnabled && SurfaceManager.opened === "network", "Ethernet toggled Wi-Fi");
                NetworkService.wifiEnabled = false; settle();
                check(wifi.glyph === Icons.ethernet && !wifi.glyphSlashed && wifi.accent,
                    "Disabled Wi-Fi changed the Ethernet state");
                NetworkService.wiredDevice = null; NetworkService.wifiEnabled = true; settle();
                keyClick(Qt.Key_L);
                check(find(loader.item, "quickBluetooth").activeFocus, "L did not move right");
                keyClick(Qt.Key_J);
                check(find(loader.item, "quickScreenshot").activeFocus, "J did not keep the right column");
                keyClick(Qt.Key_H);
                const dnd = find(loader.item, "quickDnd");
                check(dnd.activeFocus, "H did not move left");
                const before = NotificationService.dnd;
                keyClick(Qt.Key_Return);
                check(NotificationService.dnd !== before, "Enter did not activate DND");
                keyClick(Qt.Key_J);
                check(tile().activeFocus, "J did not reach Caffeinate");
                keyClick(Qt.Key_Return); settle();
                check(loader.item.caffeinateExpanded, "Enter did not open Caffeinate");
                keyClick(Qt.Key_Return); settle();
                check(!loader.item.caffeinateExpanded && tile().activeFocus, "Caffeinate selection did not close its list");
                keyClick(Qt.Key_Return); settle();
                keyClick(Qt.Key_Escape); settle();
                check(tile().activeFocus && !loader.item.caffeinateExpanded, "Escape did not return from Caffeinate");
                const volume = find(loader.item, "quickVolume");
                volume.forceActiveFocus(Qt.TabFocusReason);
                AudioService.volume = 0.4;
                keyClick(Qt.Key_L);
                check(Math.abs(AudioService.volume - 0.45) < 0.001, "L did not increase volume");
                keyClick(Qt.Key_H);
                check(Math.abs(AudioService.volume - 0.4) < 0.001, "H did not decrease volume");
                keyClick(Qt.Key_J);
                check(find(loader.item, "quickMicrophoneVolume").activeFocus, "J changed the slider instead of moving down");
                keyClick(Qt.Key_K);
                check(volume.activeFocus, "K did not return to the output slider");
                find(loader.item, "quickMute").forceActiveFocus(Qt.TabFocusReason);
                const muted = AudioService.muted;
                keyClick(Qt.Key_Space);
                check(AudioService.muted !== muted && !find(loader.item, "quickOutputAudio").expanded,
                    "Space must only mute output");
                keyClick(Qt.Key_Space);
                keyClick(Qt.Key_Return); settle();
                const devices = find(loader.item, "quickOutputDevices");
                check(devices.activeFocus, "Device picker did not take focus");
                keyClick(Qt.Key_J);
                check(devices.currentIndex === 1, "J did not select the second device");
                keyClick(Qt.Key_Return); settle();
                check(AudioService.sink === AudioService.headphones, "Enter did not select headphones");
                check(find(loader.item, "quickMute").activeFocus, "Device selection lost focus");
                check(!find(loader.item, "quickOutputAudio").expanded, "Device selection did not close its list");
                AudioService.sink = AudioService.speakers;
                NotificationService.dnd = before;
                return {passed: true};
            }
            function rapid() {
                CaffeinateService.setMode("background");
                check(CaffeinateService.busy && !CaffeinateService.active, "Mode became active before acknowledgement");
                CaffeinateService.setMode("presentation");
                CaffeinateService.setMode("off");
                CaffeinateService.setMode("secure-background");
                wait(800);
                check(CaffeinateService.mode === "secure-background" && !CaffeinateService.busy, "Rapid latest selection was lost");
                CaffeinateService.setMode("invalid");
                check(CaffeinateService.mode === "secure-background", "Invalid mode accepted");
                CaffeinateService.setMode("off");
                settle();
                return {passed: true};
            }
        }
    }
    IpcHandler {
        target: "caffeinatetest"
        function ready(): bool { return !!loader.item && !!CaffeinateService; }
        function keyboard(): string { try { return JSON.stringify(tests.keyboard()); } catch(error) { return JSON.stringify({passed: false, error: String(error)}); } }
        function audio(reduced: bool): string { try { return JSON.stringify(audioTests.run(reduced)); } catch(error) { return JSON.stringify({passed: false, error: String(error)}); } }
        function audioCycle(): string { try { return JSON.stringify(audioTests.cycle()); } catch(error) { return JSON.stringify({passed: false, error: String(error)}); } }
        function microphoneOsd(): string { try { return JSON.stringify(tests.microphoneOsd()); } catch(error) { return JSON.stringify({passed: false, error: String(error)}); } }
        function tiles(): string { return JSON.stringify(tests.tiles()); }
        function smoke(reduced: bool): string { try { return JSON.stringify(tests.smoke(reduced)); } catch(error) { return JSON.stringify({passed: false, error: String(error)}); } }
        function run(reduced: bool): string { try { return JSON.stringify(tests.run(reduced)); } catch(error) { return JSON.stringify({passed: false, error: String(error)}); } }
        function rapid(): string { try { return JSON.stringify(tests.rapid()); } catch(error) { return JSON.stringify({passed: false, error: String(error)}); } }
        function screenshot(): bool {
            CaffeinateService.setMode("background");
            tests.settle();
            loader.item.openCaffeinate(true);
            tests.settle();
            return loader.item.grabToImage(result => result.saveToFile(Quickshell.env("QS_CAFFEINATE_PROOF") + "/modes.png"));
        }
    }
}
