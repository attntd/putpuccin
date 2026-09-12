import QtQuick
import QtQuick.Layouts
import qs.core

ColumnLayout {
    id: root

    property string icon: Icons.info
    property string title: ""
    property string detail: ""

    spacing: Metrics.space8

    Text {
        text: root.icon
        color: Theme.overlay1
        font.family: Metrics.fontFamily
        font.pixelSize: 30
        Layout.alignment: Qt.AlignHCenter
    }

    Text {
        text: root.title
        color: Theme.text
        font.family: Metrics.fontFamily
        font.pixelSize: Metrics.fontBody
        font.weight: Font.DemiBold
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        Layout.fillWidth: true
    }

    Text {
        visible: root.detail.length > 0
        text: root.detail
        color: Theme.subtext0
        font.family: Metrics.fontFamily
        font.pixelSize: Metrics.fontSmall
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        Layout.fillWidth: true
    }
}
