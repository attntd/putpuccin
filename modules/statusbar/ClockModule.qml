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
    readonly property var polishLocale: Qt.locale("pl_PL")
    readonly property string expansionSurface: "calendar"
    readonly property int expansionWidth: Metrics.popupWidth
    readonly property Component expansionComponent: calendarExpansion
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    BarButton {
        id: button
        anchors.fill: parent
        icon: Icons.clock
        iconAtEnd: true
        foreground: Theme.text
        text: root.polishLocale.toString(clock.date, Settings.clockDateFormat)
            + " " + root.polishLocale.toString(clock.date, Settings.clockFormat)
        compact: Settings.option("clock", "presentation", "adaptive") === "icon"
        active: SurfaceManager.isOpen("calendar", root.screenName)
        tooltip: root.polishLocale.toString(clock.date, "dddd, d MMMM yyyy")
        onClicked: ModuleActions.run("clock", "primary", root.screenName)
        onRightClicked: ModuleActions.run("clock", "secondary", root.screenName)
    }

    Component {
        id: calendarExpansion
        CalendarPopup { screenName: root.screenName; embedded: true }
    }
}
