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
    readonly property string expansionSurface: "quickSettings"
    readonly property int expansionWidth: Metrics.popupWidth
    readonly property Component expansionComponent: quickExpansion
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    BarButton {
        id: button
        anchors.fill: parent
        icon: Icons.quickSettings
        iconForeground: Theme.text
        compact: Settings.option("quickSettings", "presentation", "adaptive") !== "label"
        text: Strings.quickSettings
        tooltip: Strings.quickSettings
        active: SurfaceManager.isOpen("quickSettings", root.screenName)
        onClicked: ModuleActions.run("quickSettings", "primary", root.screenName)
    }
    Component {
        id: quickExpansion
        QuickSettingsPopup { screenName: root.screenName; embedded: true }
    }
}
