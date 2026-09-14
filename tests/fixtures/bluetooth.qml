//@ pragma ShellId bluetooth-ui-test
import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtTest
import Quickshell
import Quickshell.Io
import qs.core
import qs.services
import qs.popups
import qs.audit

ShellRoot {
    Component {
        id: scanDevice
        QtObject {
            property string name: ""
            property string deviceName: ""
            property string address: ""
            property string dbusPath: "/org/bluez/hci0/dev_" + address.replace(/:/g, "_")
            property var adapter: Bluetooth.firstAdapter
            property bool paired: false
            property bool bonded: false
            property bool connected: false
            property bool pairing: false
            property int state: 0
            property bool batteryAvailable: false
            property real battery: 0
        }
    }
    Window {
        id: window
        visible: true
        width: Metrics.popupWidth + 40
        height: 850
        color: Theme.base
        Loader {
            id: loader
            active: false
            x: 20; y: 20; width: Metrics.popupWidth
            sourceComponent: BluetoothPopup { screenName: "test-a"; height: implicitHeight }
        }
        TestCase {
            id: test
            when: false
            function check(value, message) { if (!value) throw new Error(message); }
            function find(item, name) {
                if (item.objectName === name) return item;
                for (const child of item.children || []) {
                    const found = find(child, name);
                    if (found) return found;
                }
                return null;
            }
            function settle() { wait(35); check(waitForPolish(window, 500), "Layout did not settle"); }
            function click(item) {
                check(!!item && item.visible && item.enabled, "Control is missing, hidden or disabled: " + (item ? item.objectName : ""));
                mouseClick(item, item.width/2, item.height/2); settle();
            }
            function open() {
                loader.active = true; settle();
                check(BluetoothService.popupOpen, "Popup was not acquired");
                check(!Bluetooth.defaultAdapter.discovering, "Saved devices started discovery");
            }
            function close() {
                loader.active = false; settle();
                check(loader.item === null && !BluetoothService.popupOpen, "Popup was retained");
                check((!Bluetooth.defaultAdapter || !Bluetooth.defaultAdapter.discovering)
                    && !BluetoothService.pairingBusy, "Work survived popup destruction");
            }
            function begin(prompt) {
                Fixture.nextPrompt = prompt;
                open();
                click(find(loader.item, "pairNewDevice"));
                check(loader.item.keepOpen && Bluetooth.defaultAdapter.discovering, "Picker did not own discovery");
                const nearby = find(loader.item, "availableBluetoothDevices");
                check(nearby.count === 1, "Saved or foreign adapter device shown as nearby");
                nearby.currentIndex = 0; nearby.forceActiveFocus(); keyClick(Qt.Key_Return); settle();
                check(BluetoothService.pairingBusy, "Enter did not start pairing");
                check(!Bluetooth.defaultAdapter.discovering, "Pairing did not pause scanning");
                check(loader.item.keepOpen, "Pairing is not retained");
            }
            function run(prompt, cancel) {
                begin(prompt);
                const input = find(loader.item, "bluetoothPinInput");
                const confirm = find(loader.item, "bluetoothConfirmPairing");
                if (prompt === "pin" || prompt === "passkey") {
                    check(input.visible && input.activeFocus, "Input lacks focus");
                    check(!confirm.enabled, "Empty code accepted");
                    input.text = prompt === "pin" ? "00Ab" : "000042";
                    settle(); check(confirm.enabled, "Valid code rejected");
                }
                if (["confirmation", "displayPin", "displayPasskey"].indexOf(prompt) >= 0)
                    check(find(loader.item, "bluetoothPairingCode").text === "000042", "Code lost leading zeroes");
                if (cancel) click(find(loader.item, "bluetoothCancelPairing"));
                else if (prompt === "displayPin" || prompt === "displayPasskey") {
                    check(!confirm.visible, "Displayed code requires an extra confirmation");
                    Fixture.agent.complete("", true);
                } else if (prompt === "pin" || prompt === "passkey") keyClick(Qt.Key_Return);
                else click(confirm);
                settle();
                check(!BluetoothService.pairingBusy, "Pairing did not finish");
                if (!cancel) check(BluetoothService.statusMessage === "" && !find(loader.item, "bluetoothFeedback").visible,
                    "Successful pairing shows redundant feedback");
                close();
                return {passed: true, prompt: prompt, cancelled: cancel};
            }
            function lifecycle() {
                const original = Bluetooth.devices;
                const extra = populatePicker();
                open(); click(find(loader.item, "pairNewDevice"));
                const list = find(loader.item, "availableBluetoothDevices");
                list.forceActiveFocus(); keyClick(Qt.Key_End); settle();
                check(list.currentIndex === extra.length - 1 && list.contentY > 0, "Full-list cycle lost its last device");
                close();
                Bluetooth.devices = original;
                extra.forEach(device => device.destroy());
                open();
                click(find(loader.item, "bluetoothDeviceSettings_0"));
                click(find(loader.item, "bluetoothRename"));
                click(find(loader.item, "bluetoothCancelRename"));
                click(find(loader.item, "bluetoothForget"));
                click(find(loader.item, "bluetoothCancelForget"));
                close();
                check(!BluetoothService.managementPath, "Settings survive a lifecycle cycle");
                begin("pin");
                BluetoothService.acquirePopup("test-b");
                BluetoothService.releasePopup("test-b");
                check(BluetoothService.pairingBusy, "Another monitor canceled pairing");
                close();
                begin("confirmation");
                Bluetooth.defaultAdapter.enabled = false; settle();
                check(!BluetoothService.pairingBusy && !Bluetooth.defaultAdapter.discovering, "Radio off retained pairing");
                close(); Bluetooth.defaultAdapter.enabled = true;
                begin("pin");
                Fixture.agent.complete("org.bluez.Error.AuthenticationFailed", false); settle();
                check(BluetoothService.errorMessage === Strings.bluetoothPairAuthFailed, "Wrong error feedback");
                close();
                open();
                click(find(loader.item, "pairNewDevice"));
                Bluetooth.adapters = {values: []}; Bluetooth.defaultAdapter = null; settle();
                check(!Bluetooth.firstAdapter.discovering, "Removed adapter retained discovery");
                check(!BluetoothService.available && !find(loader.item, "pairNewDevice").enabled, "Missing adapter remains interactive");
                close(); Bluetooth.defaultAdapter = Bluetooth.firstAdapter;
                Bluetooth.adapters = {values: [Bluetooth.firstAdapter]};
                begin("confirmation");
                const devices = Bluetooth.devices;
                Bluetooth.devices = {values: [Bluetooth.saved]}; settle();
                check(!BluetoothService.pairingBusy, "Removed device retained pairing");
                close(); Bluetooth.devices = devices;
                return {passed: true};
            }
            function capture(prompt, path) {
                const original = Bluetooth.devices;
                let extra = [];
                if (prompt === "picker" || prompt === "picker-small") {
                    extra = populatePicker();
                    open();
                    if (prompt === "picker-small") loader.item.maximumHeight = 340;
                    click(find(loader.item, "pairNewDevice"));
                } else if (prompt === "details" || prompt === "rename" || prompt === "forget") {
                    open();
                    click(find(loader.item, "bluetoothDeviceSettings_0"));
                    if (prompt === "rename") click(find(loader.item, "bluetoothRename"));
                    if (prompt === "forget") click(find(loader.item, "bluetoothForget"));
                } else if (prompt === "adapters") {
                    Bluetooth.adapters = {values: [Bluetooth.firstAdapter, Bluetooth.foreignAdapter]};
                    open();
                } else begin(prompt);
                loader.item.grabToImage(result => result.saveToFile(path));
                wait(200);
                const height = loader.item.implicitHeight;
                close();
                Bluetooth.devices = original;
                extra.forEach(device => device.destroy());
                Bluetooth.adapters = {values: [Bluetooth.firstAdapter]};
                return JSON.stringify({height: height});
            }
            function populatePicker() {
                const labels = ["Telefon", "", "Słuchawki", "Słuchawki", "Głośnik kuchenny",
                    "Klawiatura", "Mysz", "Tablet", "Telewizor", "Kontroler", "Radio",
                    "Laptop", "Czytnik", "Zegarek", "Soundbar", "Głośnik biurowy",
                    "Drukarka", "Słuchawki sportowe", "Projektor", "Zestaw samochodowy",
                    "Pilot", "Telefon służbowy", "Klawiatura biurowa", "Zestaw głośnomówiący"];
                const values = labels.map((label, i) => {
                    const address = "AA:BB:CC:DD:EE:" + i.toString(16).padStart(2, "0").toUpperCase();
                    return scanDevice.createObject(test, {name: i < 2 ? address.replace(/:/g, "-") : label,
                        deviceName: label, address: address});
                });
                Bluetooth.devices = {values: [Bluetooth.saved, Bluetooth.foreign].concat(values)};
                return values;
            }
            function picker() {
                const original = Bluetooth.devices;
                const values = populatePicker();
                open(); click(find(loader.item, "pairNewDevice"));
                let list = find(loader.item, "availableBluetoothDevices");
                check(list.count === values.length && list.count > 4, "Picker truncated discovered devices");
                check(!find(loader.item, "savedBluetoothDevices").visible, "Picker is still an inline section");
                check(list.contentHeight > list.height && list.height <= Metrics.bluetoothPickerListHeight,
                    "List does not have a bounded scrolling viewport");
                const bar = find(list, "bluetoothDeviceScrollBar");
                check(bar && bar.visible && bar.policy === ScrollBar.AlwaysOn, "Scrolling has no visible scrollbar");
                check(BluetoothService.deviceName(values[0]) === "Telefon", "MAC alias hides the real device name");
                check(BluetoothService.deviceName(values[1]) === Strings.bluetoothUnnamed, "MAC is still used as the primary label");
                list.currentIndex = 0; list.forceActiveFocus(); settle();
                const name = find(list.currentItem, "bluetoothDeviceName_0");
                const address = find(list.currentItem, "bluetoothDeviceAddress_0");
                check(name && name.visible && !address, "Picker should display the name without a MAC address");
                const deviceButton = list.currentItem.children[0];
                // The offscreen platform has no desktop hover style hint.
                deviceButton.hoverEnabled = true;
                mouseMove(window, 0, 0);
                mouseMove(deviceButton, deviceButton.width / 2, deviceButton.height / 2); wait(750);
                check(deviceButton.hovered, "Pointer did not enter the device row");
                check(!deviceButton.ToolTip.visible, "Hover shows a device tooltip");
                keyClick(Qt.Key_End); settle();
                check(list.currentIndex === list.count - 1 && list.contentY > 0, "Keyboard cannot reach the last device");
                keyClick(Qt.Key_Home); settle();
                const grip = bar.visualSize * bar.height / 2;
                mousePress(bar, bar.width / 2, grip);
                mouseMove(bar, bar.width / 2, bar.height - grip, 100);
                mouseRelease(bar, bar.width / 2, bar.height - grip); settle();
                check(list.contentY > 0, "Scrollbar thumb does not drag");
                list.forceActiveFocus(); keyClick(Qt.Key_Home); settle();
                mouseWheel(list, list.width / 2, list.height / 2, 0, -600); wait(300);
                check(list.contentY > 0, "Wheel does not scroll the list");
                values[1].deviceName = "Nowo wykryty telefon"; settle();
                check(BluetoothService.deviceName(values[1]) === "Nowo wykryty telefon" && list.count === values.length,
                    "Resolved names do not update live");
                click(find(loader.item, "bluetoothPickerBack"));
                check(!Bluetooth.firstAdapter.discovering && !find(loader.item, "availableBluetoothDevices"),
                    "Going back retained discovery or picker");
                check(find(loader.item, "pairNewDevice").activeFocus, "Back did not restore keyboard focus");
                loader.item.maximumHeight = 340;
                click(find(loader.item, "pairNewDevice"));
                check(loader.item.implicitHeight <= 340, "Picker does not fit a short screen");
                list = find(loader.item, "availableBluetoothDevices");
                list.forceActiveFocus(); keyClick(Qt.Key_End); settle();
                keyClick(Qt.Key_K);
                check(list.currentIndex === list.count - 2, "K did not move up the discovered devices");
                keyClick(Qt.Key_J);
                check(list.currentIndex === list.count - 1, "J did not return to the last device");
                const chosen = list.currentItem.modelData.dbusPath;
                keyClick(Qt.Key_Return); settle();
                check(BluetoothService.pairingPath === chosen && !Bluetooth.firstAdapter.discovering,
                    "Cannot pair a device reached by scrolling");
                close();
                Bluetooth.devices = original;
                values.forEach(device => device.destroy());
                return {passed: true, devices: values.length, scrollWheel: true, scrollbarDrag: true, keyboardEnd: true,
                    nameOnly: true, noDeviceTooltip: true, asynchronousName: true, compactViewport: true, silentRemoval: true};
            }
            function management() {
                open();
                let saved = find(loader.item, "savedBluetoothDevices");
                check(saved.count === 1, "Saved list includes another adapter");
                check(!find(saved, "bluetoothDeviceAddress_0"), "Main view exposes a MAC address");
                saved.currentIndex = 0; saved.forceActiveFocus(); keyClick(Qt.Key_L); settle();
                check(loader.item.managingHere && loader.item.keepOpen, "Keyboard did not open retained settings");
                let input = find(loader.item, "bluetoothNameInput");
                const renameButton = find(loader.item, "bluetoothRename");
                const name = find(loader.item, "bluetoothDetailsName");
                const address = find(loader.item, "bluetoothDetailsAddress");
                check(!input.visible && renameButton.visible && renameButton.activeFocus, "Details start in edit mode");
                check(name.text === Bluetooth.saved.name && address.text === Bluetooth.saved.address,
                    "Details header shows the wrong name or address");
                check(Math.abs(name.y + name.baselineOffset - address.y - address.baselineOffset) < 1,
                    "Name and MAC are not on the same baseline in details");
                check(name.x + name.width <= address.x && address.x + address.width <= address.parent.width,
                    "Details header overlaps or overflows");
                keyClick(Qt.Key_Space); settle();
                check(input.visible && input.activeFocus, "Name field lacks focus");
                input.text = "";
                for (const key of [Qt.Key_H, Qt.Key_J, Qt.Key_K, Qt.Key_L]) keyClick(key);
                check(input.text === "hjkl" && input.activeFocus, "Vim keys intercepted the name editor");
                input.text = "Niezapisana nazwa"; settle();
                let renameCalls = Fixture.actions.calls;
                click(find(loader.item, "bluetoothCancelRename"));
                check(!input.visible && renameButton.activeFocus && Fixture.actions.calls === renameCalls,
                    "Cancel rename saved the draft or lost focus");
                click(renameButton);
                check(input.text === Bluetooth.saved.name, "Rename retained an abandoned draft");
                input.text = "Słuchawki biurowe"; settle();
                keyClick(Qt.Key_Return); settle();
                check(Bluetooth.saved.name === "Słuchawki biurowe", "Enter did not rename");
                check(BluetoothService.statusMessage === Strings.bluetoothRenamed, "Rename lacks success");
                check(!input.visible && renameButton.activeFocus, "Successful rename did not return to details");
                click(renameButton);
                click(find(loader.item, "bluetoothResetName"));
                check(Bluetooth.saved.name === Bluetooth.saved.deviceName, "Default name was not restored");
                check(!BluetoothService.validName("a\nname") && !BluetoothService.validName("ą".repeat(125)), "Invalid name accepted");

                Fixture.holdAction = true;
                click(renameButton);
                input.text = "Odrzucona nazwa"; settle();
                click(find(loader.item, "bluetoothSaveName"));
                check(BluetoothService.actionBusy && !find(loader.item, "bluetoothSaveName").enabled, "Duplicate rename enabled");
                check(Bluetooth.saved.name === "Słuchawki" && BluetoothService.statusMessage === "", "Rename claimed success before reply");
                Fixture.actions.complete("org.bluez.Error.NotAuthorized"); settle();
                check(BluetoothService.errorMessage === Strings.bluetoothActionDenied, "Denied rename lacks feedback");
                check(input.visible && input.text === "Odrzucona nazwa", "Failed rename discarded the draft");
                Fixture.holdAction = false;
                click(find(loader.item, "bluetoothSaveName"));
                check(Bluetooth.saved.name === "Odrzucona nazwa", "Rename cannot retry");
                click(renameButton);
                click(find(loader.item, "bluetoothResetName"));

                let calls = Fixture.actions.calls;
                click(find(loader.item, "bluetoothForget"));
                check(Fixture.actions.calls === calls && Bluetooth.devices.values.indexOf(Bluetooth.saved) >= 0,
                    "Forget ran before confirmation");
                check(find(loader.item, "bluetoothCancelForget").activeFocus, "Destructive confirmation takes default focus");
                keyClick(Qt.Key_Space); settle();
                check(Fixture.actions.calls === calls && find(loader.item, "bluetoothForget").visible,
                    "Default confirmation action did not cancel removal");
                click(find(loader.item, "bluetoothForget"));
                const devices = Bluetooth.devices;
                Fixture.holdAction = true;
                click(find(loader.item, "bluetoothConfirmForget"));
                check(!find(loader.item, "bluetoothConfirmForget").enabled, "Duplicate removal enabled");
                Fixture.actions.complete("org.bluez.Error.Failed"); settle();
                check(loader.item.managingHere && BluetoothService.errorMessage === Strings.bluetoothForgetFailed,
                    "Failed removal lost selection or feedback");
                Fixture.holdAction = false;
                click(find(loader.item, "bluetoothConfirmForget"));
                check(!loader.item.managingHere && Bluetooth.devices.values.indexOf(Bluetooth.saved) < 0, "Confirmed removal did not finish");
                check(BluetoothService.statusMessage === "" && !find(loader.item, "bluetoothFeedback").visible, "Removal shows redundant feedback");
                Bluetooth.devices = devices; settle();

                // Connecting is backed by the native command result as well.
                Fixture.holdAction = true;
                check(BluetoothService.toggleDevice(Bluetooth.saved), "Connection did not start");
                check(!BluetoothService.toggleDevice(Bluetooth.saved), "Concurrent connection accepted");
                Fixture.actions.complete("org.bluez.Error.Failed"); settle();
                check(BluetoothService.errorMessage === Strings.bluetoothConnectionFailed, "Connection error was hidden");
                Fixture.holdAction = false;
                check(BluetoothService.toggleDevice(Bluetooth.saved), "Cannot retry connection"); settle();
                check(Bluetooth.saved.connected, "Connection retry failed");
                check(BluetoothService.statusMessage === "" && !find(loader.item, "bluetoothFeedback").visible,
                    "Connection shows redundant bottom feedback");
                check(BluetoothService.toggleDevice(Bluetooth.saved), "Disconnection did not start"); settle();
                check(!Bluetooth.saved.connected, "Disconnection failed");
                check(BluetoothService.statusMessage === "" && !find(loader.item, "bluetoothFeedback").visible,
                    "Disconnection shows redundant bottom feedback");

                // Settings remain available with the radio off.
                Bluetooth.firstAdapter.enabled = false; settle();
                click(find(loader.item, "bluetoothDeviceSettings_0"));
                check(loader.item.managingHere, "Radio off blocks saved-device settings");
                BluetoothService.acquirePopup("test-b"); BluetoothService.releasePopup("test-b");
                check(loader.item.managingHere, "Other monitor closed settings");
                close();
                check(!BluetoothService.managementPath, "Settings survive popup destruction");
                Bluetooth.firstAdapter.enabled = true;

                // Selection changes the lists, radio and discovery together.
                Bluetooth.adapters = {values: [Bluetooth.firstAdapter, Bluetooth.foreignAdapter]};
                open();
                click(find(loader.item, "pairNewDevice"));
                check(Bluetooth.firstAdapter.discovering, "Initial adapter does not scan");
                click(find(loader.item, "bluetoothAdapter_hci1"));
                check(BluetoothService.adapter === Bluetooth.foreignAdapter, "Adapter picker did not select USB");
                check(!Bluetooth.firstAdapter.discovering && Bluetooth.foreignAdapter.discovering, "Discovery did not transfer");
                saved = find(loader.item, "savedBluetoothDevices");
                check(saved.count === 1 && saved.devices[0] === Bluetooth.foreign, "Saved list did not follow adapter");
                Bluetooth.adapters = {values: [Bluetooth.firstAdapter]}; settle();
                check(BluetoothService.adapter === Bluetooth.firstAdapter && !Bluetooth.foreignAdapter.discovering,
                    "Hotplug retained absent adapter");
                close();
                check(!Bluetooth.firstAdapter.discovering, "Discovery survived close");
                return {passed: true, rename: true, explicitRename: true, cancelRename: true, inlineAddress: true,
                    silentConnection: true, reset: true, forgetConfirmation: true,
                    errorsAndRetry: true, keyboard: true, radioOff: true, adaptersAndHotplug: true};
            }
        }
    }
    IpcHandler {
        target: "bluetoothTest"
        function ready(): bool { return true; }
        function run(prompt: string, cancel: bool): string {
            try { return JSON.stringify(test.run(prompt, cancel)); }
            catch (error) { return JSON.stringify({passed: false, error: String(error)}); }
        }
        function lifecycle(): string {
            try { return JSON.stringify(test.lifecycle()); }
            catch (error) { return JSON.stringify({passed: false, error: String(error)}); }
        }
        function capture(prompt: string, path: string): string { return test.capture(prompt, path); }
        function management(): string {
            try { return JSON.stringify(test.management()); }
            catch (error) { return JSON.stringify({passed: false, error: String(error)}); }
        }
        function picker(): string {
            try { return JSON.stringify(test.picker()); }
            catch (error) { return JSON.stringify({passed: false, error: String(error)}); }
        }
    }
}
