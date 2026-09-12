pragma ComponentBehavior: Bound
import QtQuick
import qs.components
import qs.core
import qs.services
import qs.modules.notifications

Item {
    id: root
    property var barWindow
    property var shellScreen
    readonly property string screenName: HyprlandService.screenName(shellScreen)
    readonly property string expansionSurface: "notifications"
    readonly property int expansionWidth: Metrics.popupWidth
    readonly property Component expansionComponent: notificationExpansion
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    BarButton {
        id: button
        anchors.fill: parent
        icon: NotificationService.dnd ? Icons.notificationOff : Icons.notification
        iconForeground: NotificationService.dnd ? Theme.red
            : NotificationService.count > 0 ? Theme.accent : Theme.text
        text: Settings.option("notifications", "presentation", "adaptive") === "label"
            ? Strings.notifications : ""
        compact: Settings.option("notifications", "presentation", "adaptive") !== "label"
        warning: NotificationService.state === "unavailable" || NotificationService.state === "error"
        active: SurfaceManager.isOpen("notifications", root.screenName)
        tooltip: NotificationService.tooltip || Strings.notifications
        onClicked: ModuleActions.run("notifications", "primary", root.screenName)
        onRightClicked: ModuleActions.run("notifications", "secondary", root.screenName)
    }
    Component {
        id: notificationExpansion
        NotificationCenter {
            screenName: root.screenName
            onSearchFocusRequested: root.barWindow.activateNotificationSearch()
            maximumHeight: Math.max(0, (root.shellScreen ? root.shellScreen.height : 900)
                - Settings.barHeight - 2 * Settings.topMargin) * Settings.notificationCenterHeightFraction
        }
    }
}
