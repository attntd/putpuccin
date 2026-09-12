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
    readonly property string expansionSurface: "launcher"
    readonly property int expansionWidth: 430
    readonly property Component expansionComponent: launcherExpansion
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    BarButton {
        id: button
        anchors.fill: parent
        icon: Icons.launcher
        text: Settings.option("launcher", "presentation", "adaptive") === "label" ? Strings.applications : ""
        compact: Settings.option("launcher", "presentation", "adaptive") !== "label"
        tooltip: Strings.launchApplication
        onClicked: ModuleActions.run("launcher", "primary", root.screenName)
        onRightClicked: ModuleActions.run("launcher", "secondary", root.screenName)
    }

    Component {
        id: launcherExpansion
        LauncherPopup {
            screenName: root.screenName
            embedded: true
            onSearchFocusRequested: root.barWindow.activateLauncherSearch()
        }
    }
}
