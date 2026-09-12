pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Services.UPower
import qs.components
import qs.core
import qs.popups
import qs.services

Item {
    id: root
    property var barWindow
    property var shellScreen
    readonly property string screenName: HyprlandService.screenName(shellScreen)
    readonly property string expansionSurface: "battery"
    readonly property int expansionWidth: Metrics.popupWidth
    readonly property Component expansionComponent: batteryExpansion
    readonly property string profileIcon: PowerService.profile === PowerProfile.Performance ? Icons.profilePerformance
        : PowerService.profile === PowerProfile.PowerSaver ? Icons.profileSaver : Icons.battery
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    BarButton {
        id: button
        anchors.fill: parent
        icon: root.profileIcon
        foreground: Theme.text
        iconForeground: Theme.text
        text: PowerService.batteryAvailable ? PowerService.percentage + "%" : PowerService.profileName
        compact: Settings.option("battery", "presentation", "adaptive") === "icon"
        warning: PowerService.batteryAvailable && PowerService.percentage <= 15 && !PowerService.charging
        active: SurfaceManager.isOpen("battery", root.screenName)
        tooltip: PowerService.batteryAvailable
            ? Strings.battery + ": " + PowerService.percentage + "% · " + PowerService.profileName
            : Strings.powerProfile + ": " + PowerService.profileName
        onClicked: ModuleActions.run("battery", "primary", root.screenName)
        onRightClicked: ModuleActions.run("battery", "secondary", root.screenName)
    }

    Component {
        id: batteryExpansion
        BatteryPopup { screenName: root.screenName; embedded: true }
    }
}
