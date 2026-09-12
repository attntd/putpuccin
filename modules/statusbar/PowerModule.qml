pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.components
import qs.core
import qs.popups
import qs.services

Item {
    id: root
    property var barWindow
    property var shellScreen
    readonly property string screenName: HyprlandService.screenName(shellScreen)
    readonly property string expansionSurface: "power"
    readonly property int expansionWidth: 360
    readonly property Component expansionComponent: powerExpansion
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    BarButton {
        id: button
        anchors.fill: parent
        icon: Icons.power
        iconForeground: Theme.red
        text: Settings.option("power", "presentation", "adaptive") === "label" ? Strings.power : ""
        compact: Settings.option("power", "presentation", "adaptive") !== "label"
        active: SurfaceManager.isOpen("power", root.screenName)
        tooltip: Strings.power
        onClicked: ModuleActions.run("power", "primary", root.screenName)
        onRightClicked: ModuleActions.run("power", "secondary", root.screenName)
    }

    Component {
        id: powerExpansion
        PowerPopup { screenName: root.screenName; embedded: true }
    }
}
