//@ pragma ShellId network-ui-test
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
import qs.modules.network

ShellRoot {
    NetworkWindow { id: manager }
    readonly property var panel: manager.item ? test.find(manager.item.contentItem, "networkWindowContent") : null
    Window {
        id: window
        visible: true
        width: Metrics.popupWidth + 40
        height: 780
        color: Theme.base
        Loader {
            id: loader
            active: false
            x: 20; y: 20; width: Metrics.popupWidth
            sourceComponent: NetworkPopup { screenName: "test-a"; height: implicitHeight; maximumHeight: 650 }
        }
        TestCase {
            id: test
            parent: panel || window.contentItem
            when: false
            function check(value, message) { if (!value) throw new Error(message); }
            function find(item, name) {
                if (!item) return null;
                if (item.objectName === name) return item;
                for (const child of item.children || []) {
                    const found = find(child, name); if (found) return found;
                }
                return null;
            }
            function settle() { wait(60); if (manager.item) check(waitForPolish(panel, 500), "Layout did not settle"); }
            function click(item) {
                check(item && item.visible && item.enabled, "Missing/disabled control: "+(item?item.objectName:"null"));
                mouseClick(item, item.width/2, item.height/2);settle();
            }
            function type(item, value) { item.forceActiveFocus();for (const character of value) keyClick(character); }
            function open() { SurfaceManager.openOn("network","test-a");loader.active=true;settle(); }
            function close() { NetworkService.closeAdvanced("");SurfaceManager.closeOn("test-a");loader.active=false;settle(); }
            function list() {
                open();check(Networking.wifi.scannerEnabled,"List did not scan");
                click(find(loader.item,"networkAdvanced"));
                check(!!panel && !SurfaceManager.isOpen("network","test-a"),"Advanced did not open a separate window");
                loader.active=false;settle();
                check(NetworkService.settingsOpen,"Closing the popup closed the independent window");
                click(find(panel,"networkSavedTab"));
                const list=find(panel,"networkSavedList");
                check(list.count===24 && list.contentHeight>list.height,"Saved list is capped or not scrollable");
                check(!Networking.wifi.scannerEnabled,"Saved settings scan");
                list.currentIndex=23;list.positionViewAtIndex(23,ListView.Contain);settle();
                check(list.contentY>0,"Cannot scroll to the last profile");
                list.currentIndex=0;list.positionViewAtIndex(0,ListView.Beginning);
                return {count:list.count,height:list.height,windowWidth:manager.item.width,windowHeight:manager.item.height,passed:true};
            }
            function edit() {
                open();NetworkService.openAdvanced("test-a");settle();
                if(NetworkService.editingUuid)NetworkService.closeProfile();
                panel.section="wifi";panel.savedWifi=true;settle();
                NetworkService.editProfile("11111111-1111-1111-1111-000000000001");
            }
            function ipv4(path) {
                check(!!find(panel,"networkNameInput"),"Profile editor not created");
                click(find(panel,"networkTab1"));
                const method=find(panel,"networkIpMethodInput");
                method.forceActiveFocus();keyClick(Qt.Key_Space);keyClick(Qt.Key_Down);keyClick(Qt.Key_Return);settle();
                check(find(panel,"networkAddresses").visible,"Manual IPv4 fields absent");
                const addresses=find(panel,"networkAddressesInput");addresses.forceActiveFocus();type(addresses,"192.168.1.20/24, 192.168.1.21/24");
                const gateway=find(panel,"networkGatewayInput");gateway.forceActiveFocus();type(gateway,"192.168.1.1");
                const dns=find(panel,"networkDnsInput");dns.forceActiveFocus();keyClick(Qt.Key_A,Qt.ControlModifier);type(dns,"1.1.1.1, 9.9.9.9");
                settle();
                const height=panel.height;check(height<680,"Form exceeded window bounds");
                test.find(manager.item.contentItem,"networkWindowLayout").grabToImage(result=>result.saveToFile(path));wait(120);
                click(find(panel,"networkSave"));
                return {height:height,passed:true};
            }
            function rename(value) {
                click(find(panel,"networkTab0"));
                const name=find(panel,"networkNameInput");name.forceActiveFocus();keyClick(Qt.Key_A,Qt.ControlModifier);type(name,value);
                settle();click(find(panel,"networkSave"));
            }
            function invalidDns() {
                click(find(panel,"networkTab2"));
                find(panel,"networkIpMethod").selected("auto");settle();
                const dns=find(panel,"networkDnsInput");dns.forceActiveFocus();keyClick(Qt.Key_A,Qt.ControlModifier);type(dns,"999.1.1.1");
                settle();click(find(panel,"networkSave"));
            }
            function forget() {
                click(find(panel,"networkForget"));
                check(find(panel,"networkCancelForget").activeFocus,"Destructive confirmation has wrong focus");
                click(find(panel,"networkCancelForget"));
                check(!!NetworkService.editingUuid,"Cancel forgot the profile");
                click(find(panel,"networkForget"));click(find(panel,"networkConfirmForget"));
                return {passed:true};
            }
            function cycle() {
                close();open();click(find(loader.item,"networkAdvanced"));loader.active=false;settle();
                check(!!manager.item && !!panel,"Separate window absent");
                click(find(panel,"networkVpnSection"));
                check(!Networking.wifi.scannerEnabled,"VPN kept scanning");
                close();check(manager.item===null && !NetworkService.popupOpen && !NetworkService.settingsOpen
                    && !Networking.wifi.scannerEnabled,"Closed window retained resources");
                return {passed:true};
            }
        }
    }
    IpcHandler {
        target: "networkTest"
        function ready(): bool { return !!window && NetworkService.savedProfiles.length===24; }
        function state(): string { return JSON.stringify({busy:NetworkService.settingsBusy,editing:!!NetworkService.editingUuid,
            loaded:Object.keys(NetworkService.profileSettings).length>0 && !NetworkService.settingsBusy,
            error:NetworkService.settingsError,vpnError:NetworkService.vpnError,vpnCount:NetworkService.vpnProfiles.length,
            vpnState:NetworkService.vpnProfiles.length ? NetworkService.vpnProfiles[0].state : 0,preview:NetworkService.vpnPreview,scanning:Networking.wifi.scannerEnabled}); }
        function list(): string { return JSON.stringify(test.list()); }
        function edit(): void { test.edit(); }
        function ipv4(path: string): string { return JSON.stringify(test.ipv4(path)); }
        function rename(value: string): void { test.rename(value); }
        function save(): void { test.click(test.find(panel,"networkSave")); }
        function invalidDns(): void { test.invalidDns(); }
        function back(): void { test.click(test.find(panel,"networkSettingsBack")); }
        function discardBack(): void {
            test.click(test.find(panel,"networkSettingsBack"));
            if(panel.pendingAction)test.click(test.find(panel,"networkDiscard"));
        }
        function vpn(): void {
            NetworkService.openAdvanced("test-a");test.settle();panel.switchSection("vpn");test.settle();
        }
        function importVpn(path: string): bool {
            test.click(test.find(panel,"networkAddVpn"));
            return NetworkService.prepareVpn(path,"wireguard");
        }
        function addVpn(): void { test.click(test.find(panel,"networkVpnImportSave")); }
        function toggleVpn(): void { test.click(test.find(panel,"networkVpnToggle0")); }
        function editVpn(): void { test.click(test.find(panel,"networkProfileDetails0")); }
        function verifyVpnEditor(): bool { return !test.find(panel,"networkHidden").visible; }
        function cancelImport(): void {
            panel.back();test.settle();test.check(!!panel.pendingAction,"Import did not confirm discard");
            test.click(test.find(panel,"networkKeepEditing"));test.check(panel.addingVpn,"Keep editing dismissed import");
            panel.back();test.settle();test.click(test.find(panel,"networkDiscard"));
        }
        function osClose(): void { manager.item.closed();test.settle(); }
        function windowOpen(): bool { return manager.item !== null; }
        function minimize(): void { manager.item.minimized=true;test.settle();test.check(!Networking.wifi.scannerEnabled,"Minimized window scans"); }
        function reopen(): void { NetworkService.openAdvanced("test-a");test.settle();test.check(!manager.item.minimized,"Reopen did not restore window"); }

        function forget(): string { return JSON.stringify(test.forget()); }
        function cycle(): string { return JSON.stringify(test.cycle()); }
        function collect(): void { gc();test.wait(200); }
        function close(): void { test.close(); }
        function capture(path: string): void { test.settle(); test.find(manager.item.contentItem,"networkWindowLayout").grabToImage(result=>result.saveToFile(path));test.wait(120); }
        function settings(): string { return JSON.stringify(NetworkService.profileSettings); }
        function write(draft: string): void { NetworkService.saveProfile(JSON.parse(draft)); }
        function small(): string {
            test.close(); Metrics.networkWindowWidth=600;Metrics.networkWindowHeight=460;
            test.edit();test.tryVerify(()=>Object.keys(NetworkService.profileSettings).length>0 && !NetworkService.settingsBusy,5000);test.settle();
            const height=panel.height;
            const form=test.find(panel,"networkForm");
            test.check(form.height>0 && form.height<form.contentHeight,"Small window form does not scroll: "+JSON.stringify({height:form.height,content:form.contentHeight,panel:panel.height,window:manager.item.height}));
            test.close(); Metrics.networkWindowWidth=900;Metrics.networkWindowHeight=680;
            test.edit();test.tryVerify(()=>Object.keys(NetworkService.profileSettings).length>0 && !NetworkService.settingsBusy,5000);test.settle();
            return JSON.stringify({passed:true,height:height});
        }
    }
}
