pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Bluetooth
import Quickshell.Io
import BluetoothNative
import qs.core

Singleton {
    id: root

    readonly property var adapters: Bluetooth.adapters ? Bluetooth.adapters.values : []
    readonly property var adapter: adapters.find(value => value.dbusPath === internal.adapterPath)
        || Bluetooth.defaultAdapter || null
    readonly property bool available: adapter !== null
    readonly property string state: !available ? "unavailable"
        : adapter.state === BluetoothAdapterState.Enabling || adapter.state === BluetoothAdapterState.Disabling ? "loading"
        : adapter.state === BluetoothAdapterState.Blocked ? "error" : "ready"
    readonly property bool enabled: available && adapter.enabled
    readonly property var devices: Bluetooth.devices ? Bluetooth.devices.values : []
    readonly property int connectedCount: devices.filter(device => device.adapter === adapter && device.connected).length
    readonly property bool popupOpen: Object.keys(internal.popups).length > 0
    readonly property bool discovering: !!adapter && adapter.discovering
    readonly property bool pairingBusy: agent.busy
    readonly property string pairingPath: agent.devicePath
    readonly property string pairingPhase: agent.phase
    readonly property string pairingPrompt: agent.prompt
    readonly property string pairingCode: agent.code
    readonly property int pairingEntered: agent.entered
    readonly property int pairingRequestId: agent.requestId
    readonly property string pairingName: internal.pairingName
    readonly property string pairingScreenName: internal.pairingScreenName
    readonly property string errorMessage: state === "error" ? Strings.bluetoothBlocked : internal.error
    readonly property string statusMessage: internal.status
    readonly property bool actionBusy: actions.busy
    readonly property string actionPath: actions.devicePath
    readonly property string action: actions.operation
    readonly property string managementPath: internal.managementPath
    readonly property string managementScreenName: internal.managementScreenName
    readonly property var managementDevice: devices.find(device => device.dbusPath === managementPath) || null
    readonly property bool discoveryRequested: enabled && !pairingBusy
        && Object.keys(internal.discovery).length > 0
    signal deviceRenamed(string path)

    QtObject {
        id: internal
        property var popups: ({})
        property var discovery: ({})
        property var scanningAdapter: null
        property string pairingName: ""
        property string pairingScreenName: ""
        property string error: ""
        property string status: ""
        property string adapterPath: ""
        property string managementPath: ""
        property string managementScreenName: ""
    }

    function deviceName(device) {
        if (!device) return "";
        const address = String(device.address || "").replace(/[:-]/g, "").toUpperCase();
        for (const value of [device.name, device.deviceName]) {
            const name = String(value || "").trim();
            // BlueZ uses a dash-separated address as Alias until Name arrives.
            if (name && name.replace(/[:-]/g, "").toUpperCase() !== address) return name;
        }
        return Strings.bluetoothUnnamed;
    }

    function selectAdapter(path) {
        if (actionBusy || !adapters.some(value => value.dbusPath === path)) return false;
        root.cancelPairing();
        root.closeManagement(internal.managementScreenName);
        internal.error = "";
        internal.status = "";
        internal.adapterPath = path;
        return true;
    }

    function openManagement(device, screenName) {
        if (!device || !internal.popups[screenName] || pairingBusy || actionBusy
                || device.adapter !== adapter || !(device.paired || device.bonded || device.connected)) return false;
        internal.managementPath = device.dbusPath;
        internal.managementScreenName = screenName;
        internal.error = "";
        internal.status = "";
        return true;
    }

    function closeManagement(screenName) {
        if (screenName !== internal.managementScreenName) return;
        internal.managementPath = "";
        internal.managementScreenName = "";
    }

    function validName(value) {
        if (/[\u0000-\u001f\u007f]/.test(value)) return false;
        try { return encodeURIComponent(value).replace(/%[A-F\d]{2}/gi, "x").length <= 248; }
        catch (_) { return false; }
    }

    function manageDevice(operation, screenName, value) {
        const device = managementDevice;
        if (!device || screenName !== managementScreenName || !internal.popups[screenName]
                || device.adapter !== adapter || pairingBusy || actionBusy || deviceBusy(device)) return false;
        if (operation !== "rename" && operation !== "forget") return false;
        const name = String(value || "").trim();
        if (operation === "rename" && !validName(name)) return false;
        internal.error = "";
        internal.status = "";
        return actions.start(operation, device.dbusPath, name);
    }

    function acquirePopup(screenName) {
        internal.popups = Object.assign({}, internal.popups, {[screenName]: true});
    }

    function releasePopup(screenName) {
        const next = Object.assign({}, internal.popups);
        delete next[screenName];
        internal.popups = next;
        root.setDiscovery(screenName, false);
        root.closeManagement(screenName);
        if (screenName === internal.pairingScreenName)
            root.cancelPairing();
    }

    function setDiscovery(screenName, active) {
        const next = Object.assign({}, internal.discovery);
        if (active && internal.popups[screenName]) next[screenName] = true;
        else delete next[screenName];
        internal.discovery = next;
    }

    function syncDiscovery() {
        const target = root.discoveryRequested ? root.adapter : null;
        if (internal.scanningAdapter === target) return;
        if (internal.scanningAdapter) internal.scanningAdapter.discovering = false;
        internal.scanningAdapter = target;
        if (target) target.discovering = true;
    }

    function setEnabled(value) {
        internal.error = "";
        if (!value) root.cancelPairing();
        if (root.adapter) root.adapter.enabled = value;
    }

    function deviceBusy(device) {
        return device && (device.dbusPath === root.pairingPath || device.dbusPath === root.actionPath || device.pairing
            || device.state === BluetoothDeviceState.Connecting
            || device.state === BluetoothDeviceState.Disconnecting);
    }

    function toggleDevice(device) {
        if (device && device.adapter === adapter && device.adapter.enabled && !pairingBusy && !actionBusy
                && !root.deviceBusy(device)) {
            internal.error = "";
            internal.status = "";
            return actions.start(device.connected ? "disconnect" : "connect", device.dbusPath);
        }
        return false;
    }

    function pairDevice(device, screenName) {
        if (!device || !enabled || pairingBusy || actionBusy || root.deviceBusy(device) || !internal.popups[screenName]
                || device.adapter !== root.adapter || device.paired || device.bonded)
            return false;
        internal.error = "";
        internal.status = "";
        root.closeManagement(internal.managementScreenName);
        internal.pairingName = root.deviceName(device);
        internal.pairingScreenName = screenName;
        return agent.start(device.dbusPath);
    }

    function respond(requestId, value) { return agent.respond(requestId, value); }
    function cancelPairing() { agent.cancel(); }

    function pairingError(error, phase, paired) {
        if (error === "canceled") return "";
        if (paired) return phase === "trusting" ? Strings.bluetoothTrustFailed : Strings.bluetoothConnectFailed;
        if (error === "timeout" || /Timeout|NoReply/.test(error)) return Strings.bluetoothPairTimeout;
        if (/AuthenticationRejected|AuthenticationCanceled|Rejected/.test(error)) return Strings.bluetoothPairRejected;
        if (/AuthenticationFailed/.test(error)) return Strings.bluetoothPairAuthFailed;
        if (/NotReady/.test(error)) return Strings.bluetoothUnavailable;
        if (/AccessDenied|NotAuthorized/.test(error)) return Strings.bluetoothPairDenied;
        if (/InProgress|AlreadyExists/.test(error)) return Strings.bluetoothPairInProgress;
        if (error === "unavailable" || /ServiceUnknown|Disconnected|UnknownObject/.test(error))
            return Strings.bluetoothPairUnavailable;
        return Strings.bluetoothPairFailed;
    }

    PairingAgent {
        id: agent
        onFinished: (path, error, phase, paired) => {
            internal.error = error ? root.pairingError(error, phase, paired) : "";
            internal.status = "";
            internal.pairingScreenName = "";
        }
    }

    DeviceActions {
        id: actions
        onFinished: (path, operation, error) => {
            if (!error) {
                internal.error = "";
                internal.status = operation === "rename" ? Strings.bluetoothRenamed : "";
                if (operation === "rename") root.deviceRenamed(path);
                if (operation === "forget" && path === internal.managementPath)
                    root.closeManagement(internal.managementScreenName);
            } else {
                internal.status = "";
                internal.error = /AccessDenied|NotAuthorized/.test(error) ? Strings.bluetoothActionDenied
                    : error === "unavailable" || /ServiceUnknown|UnknownObject|DoesNotExist/.test(error)
                    ? Strings.bluetoothPairUnavailable
                    : operation === "rename" ? Strings.bluetoothRenameFailed
                    : operation === "forget" ? Strings.bluetoothForgetFailed
                    : operation === "connect" ? Strings.bluetoothConnectionFailed : Strings.bluetoothDisconnectFailed;
            }
        }
    }

    // Only a visible device picker owns discovery. Pairing pauses discovery;
    // the native BlueZ model remains the sole source of adapter/device state.
    onDiscoveryRequestedChanged: root.syncDiscovery()

    onEnabledChanged: {
        if (!enabled) root.cancelPairing();
    }
    onAdapterChanged: {
        root.cancelPairing();
        root.closeManagement(internal.managementScreenName);
        root.syncDiscovery();
    }
    onAdaptersChanged: {
        if (internal.adapterPath && !adapters.some(value => value.dbusPath === internal.adapterPath))
            internal.adapterPath = "";
    }
    onDevicesChanged: {
        if (pairingBusy && !devices.some(device => device.dbusPath === pairingPath))
            root.cancelPairing();
        if (managementPath && !managementDevice)
            root.closeManagement(internal.managementScreenName);
    }
    IpcHandler {
        target: "bluetooth"
        function status(): string {
            return JSON.stringify({available: root.available, enabled: root.enabled,
                discovering: root.discovering, pairing: root.pairingBusy,
                phase: root.pairingPhase, popupOpen: root.popupOpen,
                pickerOpen: Object.keys(internal.discovery).length > 0,
                adapterCount: root.adapters.length, managing: !!root.managementPath,
                actionBusy: root.actionBusy, action: root.action,
                error: root.errorMessage});
        }
    }
    Component.onDestruction: {
        agent.cancel();
        if (internal.scanningAdapter) internal.scanningAdapter.discovering = false;
    }
}
