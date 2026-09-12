pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Networking
import Quickshell.Io
import NetworkManagerNative
import qs.core

Singleton {
    id: root

    readonly property var devices: Networking.devices ? Networking.devices.values : []
    readonly property var wifiDevice: {
        for (const device of root.devices) {
            if (device.type === DeviceType.Wifi)
                return device;
        }
        return null;
    }
    readonly property var wiredDevice: {
        for (const device of root.devices) {
            if (device.type === DeviceType.Wired && device.connected)
                return device;
        }
        return null;
    }
    readonly property bool available: Networking.backend !== NetworkBackendType.None
    readonly property string state: available ? "ready" : "unavailable"
    readonly property bool wifiEnabled: Networking.wifiEnabled
    readonly property bool connected: (wifiDevice && wifiDevice.connected) || wiredDevice !== null
    readonly property var networks: wifiDevice && wifiDevice.networks ? wifiDevice.networks.values : []
    readonly property var connectedNetwork: {
        for (const network of root.networks) {
            if (network.connected)
                return network;
        }
        return null;
    }
    readonly property string displayName: wiredDevice ? "Ethernet" : (connectedNetwork ? connectedNetwork.name : "")
    readonly property real signalStrength: connectedNetwork && connectedNetwork.signalStrength !== undefined ? connectedNetwork.signalStrength : 0
    property int popupUsers: 0
    readonly property bool popupOpen: popupUsers > 0
    property string errorMessage: ""
    property string settingsScreenName: ""
    property var scanningScreens: ({})
    readonly property bool settingsOpen: settingsScreenName.length > 0
    property bool settingsScanning: false
    readonly property bool settingsBusy: editor.busy || vpn.busy
    readonly property bool vpnLoading: vpn.loading
    readonly property var vpnProfiles: vpn.profiles
    readonly property var vpnPreview: vpn.preview
    readonly property bool openVpnAvailable: vpn.openVpnAvailable
    readonly property string vpnError: settingsErrorText(vpn.error)
    readonly property string editingUuid: editor.uuid
    readonly property var profileSettings: editor.settings
    readonly property string settingsOperation: editor.operation
    readonly property string settingsError: settingsErrorText(editor.error)
    readonly property var savedProfiles: {
        const result = [], seen = {};
        for (const device of root.devices) {
            if (device.type !== DeviceType.Wifi || !device.networks) continue;
            for (const network of device.networks.values) {
                for (const profile of network.nmSettings || []) {
                    if (!profile.uuid || seen[profile.uuid]) continue;
                    seen[profile.uuid] = true;
                    result.push({uuid: profile.uuid, name: profile.id, networkName: network.name,
                        connected: network.connected, profile: profile});
                }
            }
        }
        result.sort((a, b) => a.name.localeCompare(b.name));
        return result;
    }
    signal settingsRequested()
    signal vpnAdded()
    signal profileLoaded()
    signal profileSaved()
    signal profileRemoved()

    function acquirePopup() {
        root.popupUsers += 1;
    }

    function releasePopup(screenName) {
        root.popupUsers = Math.max(0, root.popupUsers - 1);
        root.setScanning(screenName, false);
    }

    function setScanning(screenName, enabled) {
        const next = Object.assign({}, root.scanningScreens);
        if (enabled) next[screenName] = true;
        else delete next[screenName];
        root.scanningScreens = next;
    }

    function setWifiEnabled(enabled) {
        if (root.available)
            Networking.wifiEnabled = enabled;
    }

    function supportsPsk(network) {
        return network && (network.security === WifiSecurityType.WpaPsk
            || network.security === WifiSecurityType.Wpa2Psk
            || network.security === WifiSecurityType.Sae);
    }

    function validPsk(password) {
        return typeof password === "string"
            && ((password.length >= 8 && password.length <= 63)
                || /^[0-9a-fA-F]{64}$/.test(password));
    }

    function connectNetwork(network, password) {
        root.errorMessage = "";
        if (!network)
            return;
        if (network.connected) {
            network.disconnect();
        } else if (network.known || network.security === WifiSecurityType.Open
                || network.security === WifiSecurityType.Owe) {
            network.connect();
        } else if (!root.supportsPsk(network)) {
            root.errorMessage = Strings.advancedNetworkRequired;
        } else if (root.validPsk(password)) {
            network.connectWithPsk(password);
        } else {
            root.errorMessage = Strings.invalidWpaPassword;
        }
    }

    function openAdvanced(screenName) {
        const screen = screenName || SurfaceManager.focusedScreenName();
        if (!screen) return false;
        if (!SurfaceManager.prepareSettingsWindow(screen)) return false;
        if (!root.settingsOpen) { editor.clear(); root.settingsScreenName = screen; }
        root.settingsRequested();
        return true;
    }

    function closeAdvanced(screenName) {
        if (screenName && root.settingsScreenName !== screenName) return;
        root.settingsScreenName = "";
        root.settingsScanning = false;
        editor.clear();
    }
    function editProfile(uuid) {
        if (!root.settingsOpen || !root.savedProfiles.concat(root.vpnProfiles).some(profile => profile.uuid === uuid)) return false;
        return editor.load(uuid);
    }
    function closeProfile() { editor.clear(); }
    function prepareVpn(file, type) { return vpn.prepareImport(file, type); }
    function cancelVpn() { vpn.cancelImport(); }
    function addVpn(name) { return vpn.add(name); }
    function toggleVpn(uuid) { return !editor.busy && vpn.toggle(uuid); }
    function refreshVpn() { vpn.refresh(); }
    function clearVpnError() { vpn.clearError(); }
    function saveProfile(draft) { return editor.save(draft); }
    function forgetProfile() { return editor.forget(); }
    function settingsErrorText(error) {
        if (!error) return "";
        if (error === "vpn-file") return Strings.networkVpnFileError;
        if (error === "vpn-config") return Strings.networkVpnConfigError;
        if (error === "vpn-unsupported") return Strings.networkVpnUnsupported;
        if (error === "vpn-plugin") return Strings.networkVpnPluginMissing;
        if (error === "vpn-disconnected") return Strings.networkVpnConnectionFailed;
        if (error === "name") return Strings.networkInvalidName;
        if (error === "address") return Strings.networkInvalidAddress;
        if (error === "gateway") return Strings.networkInvalidGateway;
        if (error === "dns") return Strings.networkInvalidDns;
        if (error === "conflict" || error.indexOf("VersionIdMismatch") >= 0) return Strings.networkSettingsConflict;
        if (error.indexOf("Permission") >= 0 || error.indexOf("NotAuthorized") >= 0 || error.indexOf("AccessDenied") >= 0)
            return Strings.networkPermissionDenied;
        if (error === "timeout" || error.indexOf("NoReply") >= 0) return Strings.networkSettingsTimeout;
        if (error === "unavailable" || error.indexOf("UnknownConnection") >= 0 || error.indexOf("UnknownObject") >= 0)
            return Strings.networkProfileUnavailable;
        return Strings.networkSettingsFailed;
    }
    ProfileEditor {
        id: editor
        onLoaded: root.profileLoaded()
        onSaved: { root.profileSaved(); editor.clear(); }
        onRemoved: { root.profileRemoved(); editor.clear(); }
    }
    VpnProfiles {
        id: vpn
        enabled: root.settingsOpen
        onAdded: root.vpnAdded()
    }
    Connections {
        target: SurfaceManager
        function onChanged() {
            for (const screen in root.scanningScreens)
                if (!SurfaceManager.isOpen("network", screen)) root.setScanning(screen, false);
        }
    }

    Binding {
        target: root.wifiDevice
        property: "scannerEnabled"
        value: root.wifiEnabled && (root.settingsScanning || Object.keys(root.scanningScreens).length > 0)
        when: root.wifiDevice !== null
    }

    Instantiator {
        model: root.networks
        delegate: Connections {
            required property var modelData
            target: modelData
            function onConnectionFailed(reason) {
                root.errorMessage = Strings.networkConnectionFailed;
            }
            function onConnectedChanged() {
                if (modelData.connected)
                    root.errorMessage = "";
            }
        }
    }

    IpcHandler {
        target: "network"
        function settings(): void { root.openAdvanced(""); }
        function closeSettings(): void { root.closeAdvanced(""); }
        function status(): string {
            return JSON.stringify({available: root.available, enabled: root.wifiEnabled,
                connected: root.connected, popupOpen: root.popupOpen,
                scanning: root.wifiDevice ? root.wifiDevice.scannerEnabled : false,
                settingsOpen: root.settingsOpen, editing: !!root.editingUuid,
                busy: root.settingsBusy, savedCount: root.savedProfiles.length, vpnCount: root.vpnProfiles.length,
                vpnLoading: root.vpnLoading, vpnWatching: vpn.enabled});
        }
    }
}
