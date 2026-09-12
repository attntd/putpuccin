import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.core

Item {
    id: root

    property string icon: ""
    property string title: ""
    property string subtitle: ""
    property bool checked: false
    signal toggled(bool checked)

    implicitHeight: subtitle.length > 0 ? 52 : 42

    RowLayout {
        anchors.fill: parent
        spacing: Metrics.space12

        Text {
            visible: root.icon.length > 0
            text: root.icon
            color: root.checked ? Theme.accent : Theme.subtext0
            font.family: Metrics.fontFamily
            font.pixelSize: Metrics.iconLarge
        }

        ColumnLayout {
            spacing: 1
            Layout.fillWidth: true

            Text {
                text: root.title
                color: Theme.text
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.fontBody
                elide: Text.ElideRight
                Layout.fillWidth: true
            }

            Text {
                visible: root.subtitle.length > 0
                text: root.subtitle
                color: Theme.subtext0
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.fontSmall
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
        }

        PillSwitch {
            checked: root.checked
            enabled: root.enabled
            onToggled: root.toggled(checked)
        }
    }
}
