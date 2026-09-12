import QtQuick
import QtQuick.Layouts
import Quickshell.Services.SystemTray
import Quickshell.Widgets
import qs.components
import qs.core
import qs.popups
import qs.services

Item {
    id: root
    property var barWindow
    property var shellScreen
    readonly property string screenName: HyprlandService.screenName(shellScreen)
    readonly property var sortedItems: {
        const values = SystemTray.items ? SystemTray.items.values.slice() : [];
        values.sort((a, b) => {
            const aAttention = a.status === Status.NeedsAttention;
            const bAttention = b.status === Status.NeedsAttention;
            if (aAttention !== bAttention)
                return aAttention ? -1 : 1;
            return (a.title || a.id).localeCompare(b.title || b.id);
        });
        return values;
    }
    readonly property var directItems: sortedItems.slice(0, Settings.trayVisibleItems)
    readonly property var overflowItems: sortedItems.slice(Settings.trayVisibleItems)
    readonly property string expansionSurface: overflowItems.length > 0 ? "tray" : ""
    readonly property int expansionWidth: 340
    readonly property Component expansionComponent: trayExpansion

    implicitWidth: sortedItems.length > 0 ? row.implicitWidth : 0
    implicitHeight: Metrics.controlHeight
    visible: sortedItems.length > 0

    RowLayout {
        id: row
        anchors.fill: parent
        spacing: Metrics.space2

        Repeater {
            model: root.directItems
            TrayItemButton {
                required property var modelData
                trayItem: modelData
                parentWindow: root.barWindow
            }
        }

        BarButton {
            id: overflowButton
            visible: root.overflowItems.length > 0
            implicitWidth: visible ? Math.max(Metrics.minHitSize, overflowLabel.implicitWidth + Metrics.space12) : 0
            icon: Icons.more
            text: String(root.overflowItems.length)
            compact: false
            active: SurfaceManager.isOpen("tray", root.screenName)
            tooltip: Strings.moreTrayIcons
            onClicked: SurfaceManager.openOn("tray", root.screenName)
        }
    }

    Text { id: overflowLabel; visible: false; text: root.overflowItems.length }

    Component {
        id: trayExpansion
        TrayPopup {
            screenName: root.screenName
            trayItems: root.overflowItems
            barWindow: root.barWindow
            embedded: true
        }
    }

    component TrayItemButton: Item {
        id: trayButton
        required property var trayItem
        required property var parentWindow
        implicitWidth: Metrics.minHitSize
        implicitHeight: Metrics.controlHeight

        Rectangle {
            anchors.fill: parent
            radius: 10
            color: "transparent"
        }
        IconImage {
            anchors.centerIn: parent
            source: trayButton.trayItem.icon
            implicitSize: 18
        }
        MouseArea {
            id: trayMouse
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
            onClicked: mouse => {
                if (mouse.button === Qt.RightButton || trayButton.trayItem.onlyMenu) {
                    const position = trayButton.mapToItem(trayButton.parentWindow.contentItem, 0, trayButton.height);
                    trayButton.trayItem.display(trayButton.parentWindow, position.x, position.y);
                }
                else if (mouse.button === Qt.MiddleButton)
                    trayButton.trayItem.secondaryActivate();
                else
                    trayButton.trayItem.activate();
            }
            onWheel: event => trayButton.trayItem.scroll(event.angleDelta.y, false)
        }
    }
}
