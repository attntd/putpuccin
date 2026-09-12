pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import QtQuick.Layouts
import Quickshell
import qs.components
import qs.core
import qs.services

LazyLoader {
    id: loader
    active: NetworkService.settingsOpen
    component: FloatingWindow {
        id: window
        title: Strings.networkSettings
        screen: Quickshell.screens.find(screen => screen.name === NetworkService.settingsScreenName) || Quickshell.screens[0] || null
        implicitWidth: Math.min(Metrics.networkWindowWidth, screen ? screen.width - Metrics.space24 * 2 : Metrics.networkWindowWidth)
        implicitHeight: Math.min(Metrics.networkWindowHeight, screen ? screen.height - Metrics.barReservedHeight - Metrics.space24 * 2 : Metrics.networkWindowHeight)
        minimumSize: Qt.size(Math.min(Metrics.networkWindowMinimumWidth, implicitWidth), Math.min(Metrics.networkWindowMinimumHeight, implicitHeight))
        color: Theme.withAlpha(Theme.base, Settings.surfaceOpacity)
        onClosed: { visible = true; panel.requestClose(); }
        Connections {
            target: NetworkService
            function onSettingsRequested() {
                window.minimized = false;
                window.visible = true;
                const backing = panel.Window.window;
                if (backing) backing.requestActivate();
            }
        }
        ColumnLayout {
            objectName: "networkWindowLayout"
            anchors.fill: parent
            spacing: 0
            Item {
                Layout.fillWidth: true
                implicitHeight: Metrics.popupRowHeight + Metrics.space12
                MouseArea {
                    anchors.fill: parent
                    onPressed: window.startSystemMove()
                }
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Metrics.space24
                    anchors.rightMargin: Metrics.space12
                    spacing: Metrics.space12
                    Text { text: Icons.settings; color: Theme.accent; font.family: Metrics.fontFamily; font.pixelSize: Metrics.iconMedium }
                    Text { text: Strings.networkSettings; color: Theme.text; font.family: Metrics.fontFamily; font.pixelSize: Metrics.fontTitle; Layout.fillWidth: true }
                    ActionButton {
                        objectName: "networkWindowClose"
                        glyph: Icons.close
                        Accessible.name: Strings.close
                        borderless: true
                        onClicked: panel.requestClose()
                    }
                }
            }
            Rectangle { Layout.fillWidth: true; implicitHeight: Metrics.borderWidth; color: Theme.withAlpha(Theme.surface1, 0.65) }
            NetworkSettings {
                id: panel
                objectName: "networkWindowContent"
                screenName: NetworkService.settingsScreenName
                windowVisible: window.backingWindowVisible && !window.minimized
                Layout.fillWidth: true
                Layout.fillHeight: true
                onCloseRequested: NetworkService.closeAdvanced("")
            }
        }
        MouseArea {
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            width: Metrics.space12
            height: Metrics.space12
            cursorShape: Qt.SizeFDiagCursor
            onPressed: window.startSystemResize(Qt.RightEdge | Qt.BottomEdge)
        }
    }
}
