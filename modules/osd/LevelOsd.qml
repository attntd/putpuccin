import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.core
import qs.services

PanelWindow {
    id: window
    required property string screenName
    readonly property bool requested: OsdService.shown && screenName === OsdService.screenName
    anchors.bottom: true
    margins.bottom: 90
    implicitWidth: 300
    implicitHeight: 60
    visible: requested || panel.opacity > 0
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "quickshell-de:osd"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    mask: Region {}

    Rectangle {
        id: panel
        objectName: "levelOsdPanel"
        anchors.fill: parent
        radius: Metrics.popupRadius
        color: Theme.withAlpha(Theme.base, Settings.surfaceOpacity)
        opacity: window.requested ? 1 : 0
        Behavior on opacity {
            NumberAnimation { duration: Settings.reducedMotion ? Motion.fast : Motion.standard }
        }
        RowLayout {
            anchors.fill: parent
            anchors.margins: Metrics.space16
            spacing: Metrics.space12
            Item {
                implicitHeight: glyph.implicitHeight
                Layout.preferredWidth: Metrics.iconLarge
                Layout.minimumWidth: Layout.preferredWidth
                Layout.maximumWidth: Layout.preferredWidth
                Text {
                    id: glyph
                    anchors.centerIn: parent
                    text: OsdService.kind === "brightness" ? Icons.brightness : Icons.volumeHigh
                    color: OsdService.muted ? Theme.red : Theme.text
                    font.family: Metrics.fontFamily
                    font.pixelSize: Metrics.iconMedium
                    Rectangle {
                        visible: OsdService.kind === "volume" && OsdService.muted
                        anchors.centerIn: parent
                        width: parent.font.pixelSize * 1.2
                        height: 2 * Metrics.borderWidth
                        radius: height / 2
                        rotation: 45
                        antialiasing: true
                        color: parent.color
                    }
                }
            }
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: Metrics.space6
                radius: height / 2
                color: Theme.withAlpha(Theme.text, 0.12)
                Rectangle {
                    width: parent.width * (OsdService.muted ? 0 : OsdService.value)
                    height: parent.height
                    radius: parent.radius
                    color: Theme.withAlpha(Theme.accent, 0.65)
                    Behavior on width {
                        NumberAnimation { duration: Settings.reducedMotion ? 0 : Motion.fast; easing.type: Easing.OutCubic }
                    }
                }
            }
            Text {
                text: Math.round(OsdService.value * 100) + "%"
                color: Theme.text
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.fontBody
                Layout.preferredWidth: 42
                horizontalAlignment: Text.AlignRight
            }
        }
    }
}
