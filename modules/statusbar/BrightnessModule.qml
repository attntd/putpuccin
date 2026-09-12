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
    readonly property string expansionSurface: "brightness"
    readonly property int expansionWidth: 360
    readonly property Component expansionComponent: brightnessExpansion
    implicitWidth: BrightnessService.available ? button.implicitWidth : 0
    implicitHeight: button.implicitHeight
    visible: BrightnessService.available

    BarButton {
        id: button
        anchors.fill: parent
        icon: Icons.brightness
        foreground: Theme.rosewater
        iconForeground: Theme.rosewater
        text: Math.round(BrightnessService.percentage) + "%"
        compact: Settings.option("brightness", "presentation", "adaptive") === "icon"
        active: SurfaceManager.isOpen("brightness", root.screenName)
        tooltip: Strings.brightness + ": " + Math.round(BrightnessService.percentage) + "%"
        onClicked: ModuleActions.run("brightness", "primary", root.screenName)
        onRightClicked: ModuleActions.run("brightness", "secondary", root.screenName)
        onWheel: delta => ModuleActions.run("brightness", delta > 0 ? "scrollUp" : "scrollDown", root.screenName)
    }

    Component {
        id: brightnessExpansion
        BrightnessPopup { screenName: root.screenName; embedded: true }
    }
}
