pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell.Widgets
import qs.components
import qs.core

PopupFrame {
    id: root
    required property string screenName
    required property var trayItems
    required property var barWindow

    ColumnLayout {
        width: parent.width
        spacing: Metrics.space8

        SectionTitle { text: Strings.trayOverflow }

        ListView {
            id: trayList
            model: root.trayItems
            spacing: Metrics.space6
            clip: true
            activeFocusOnTab: count > 0
            keyNavigationEnabled: true
            Layout.fillWidth: true
            Layout.preferredHeight: count === 0 ? 88
                : Math.min(count, 6) * 48 + Math.max(0, Math.min(count, 6) - 1) * spacing
            ScrollBar.vertical: ScrollBar {}

            onActiveFocusChanged: {
                if (activeFocus && currentIndex < 0 && count > 0)
                    currentIndex = 0;
            }
            Keys.onReturnPressed: {
                if (currentItem)
                    currentItem.activate(false);
            }
            Keys.onEnterPressed: {
                if (currentItem)
                    currentItem.activate(false);
            }
            Keys.onSpacePressed: {
                if (currentItem)
                    currentItem.activate(false);
            }

            delegate: Rectangle {
                id: trayDelegate
                required property var modelData
                required property int index
                width: ListView.view.width - (trayList.ScrollBar.vertical.visible ? 8 : 0)
                height: 48
                radius: 10
                color: Theme.controlBackground(Theme.text, trayMouse.containsMouse)
                border.width: trayList.activeFocus && ListView.isCurrentItem ? 1 : 0
                border.color: Theme.accent

                function activate(forceMenu) {
                    if (forceMenu || trayDelegate.modelData.onlyMenu) {
                        trayDelegate.modelData.display(root.barWindow,
                            Math.max(0, root.barWindow.width - 360), Settings.reservedHeight);
                    } else {
                        trayDelegate.modelData.activate();
                        SurfaceManager.closeOn(root.screenName);
                    }
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.margins: Metrics.space8
                    IconImage {
                        source: trayDelegate.modelData.icon
                        implicitSize: 22
                    }
                    ColumnLayout {
                        spacing: 0
                        Layout.fillWidth: true
                        Text {
                            text: trayDelegate.modelData.title || trayDelegate.modelData.id
                            color: Theme.text
                            font.family: Metrics.fontFamily
                            font.pixelSize: Metrics.fontSmall
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                        Text {
                            visible: trayDelegate.modelData.tooltipDescription.length > 0
                            text: trayDelegate.modelData.tooltipDescription
                            color: Theme.subtext0
                            font.family: Metrics.fontFamily
                            font.pixelSize: 10
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                    }
                    Text {
                        text: Icons.chevronRight
                        color: Theme.overlay1
                        font.family: Metrics.fontFamily
                        font.pixelSize: Metrics.iconSmall
                    }
                }

                MouseArea {
                    id: trayMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onClicked: mouse => {
                        trayList.currentIndex = trayDelegate.index;
                        trayDelegate.activate(mouse.button === Qt.RightButton);
                    }
                }
            }

            EmptyState {
                anchors.centerIn: parent
                visible: trayList.count === 0
                icon: Icons.tray
                title: Strings.trayEmpty
            }
        }
    }
}
