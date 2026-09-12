pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import qs.components
import qs.core
import qs.services
import qs.modules.network

PopupFrame {
    id: root
    required property string screenName
    property real maximumHeight: Metrics.networkSettingsHeight
    readonly property bool ownsSurface: !embedded || SurfaceManager.isOpen("network", screenName)
    readonly property bool keepOpen: ownsSurface && nearby.passwordNetwork !== null
    readonly property bool wantsScanning: ownsSurface && NetworkService.wifiEnabled
    onWantsScanningChanged: NetworkService.setScanning(screenName, wantsScanning)
    Component.onCompleted: { NetworkService.acquirePopup(); NetworkService.setScanning(screenName, wantsScanning); }
    Component.onDestruction: NetworkService.releasePopup(screenName)
    ColumnLayout {
        width: parent.width
        spacing: Metrics.space8
        ToggleRow {
            title: Strings.wifi
            checked: NetworkService.wifiEnabled
            enabled: NetworkService.available
            Layout.fillWidth: true
            onToggled: checked => NetworkService.setWifiEnabled(checked)
        }
        NetworkNearby { id: nearby; Layout.fillWidth: true }
        ActionButton {
            text: Strings.advanced
            borderless: true
            glyph: Icons.settings
            implicitHeight: Metrics.popupRowHeight
            Layout.fillWidth: true
            objectName: "networkAdvanced"
            onClicked: NetworkService.openAdvanced(root.screenName)
        }
    }
}
