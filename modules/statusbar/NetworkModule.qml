pragma ComponentBehavior: Bound

import QtQuick
import qs.components
import qs.core
import qs.popups
import qs.services

Item {
    id: root
    property var barWindow
    property var shellScreen
    readonly property string screenName: HyprlandService.screenName(shellScreen)
    readonly property string expansionSurface: "network"
    readonly property int expansionWidth: Metrics.popupWidth
    readonly property Component expansionComponent: networkExpansion
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    BarButton {
        id: button
        anchors.fill: parent
        icon: NetworkService.wiredDevice ? Icons.ethernet : NetworkService.connected ? Icons.wifi : Icons.wifiOff
        iconForeground: NetworkService.connected
            ? Theme.accent : NetworkService.wifiEnabled
            ? Theme.blue : Theme.text
        text: Settings.option("network", "presentation", "adaptive") === "label" ? (NetworkService.displayName || Strings.network) : ""
        compact: Settings.option("network", "presentation", "adaptive") !== "label"
        warning: !NetworkService.available
        active: SurfaceManager.isOpen("network", root.screenName)
        tooltip: NetworkService.available ? (NetworkService.displayName || Strings.noConnection) : Strings.unavailable
        onClicked: ModuleActions.run("network", "primary", root.screenName)
        onRightClicked: ModuleActions.run("network", "secondary", root.screenName)
    }

    Component {
        id: networkExpansion
        NetworkPopup {
            screenName: root.screenName
            embedded: true
            maximumHeight: Math.min(Metrics.networkSettingsHeight,
                Math.max(240, (root.shellScreen ? root.shellScreen.height : 900) - Metrics.barReservedHeight - Metrics.space24))
        }
    }
}
