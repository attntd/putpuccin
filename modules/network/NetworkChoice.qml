import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.core

ColumnLayout {
    id: root
    property string title: ""
    property var options: []
    property var value
    signal selected(var value)
    spacing: Metrics.space4
    Text {
        text: root.title
        textFormat: Text.PlainText
        color: Theme.subtext0
        font.family: Metrics.fontFamily
        font.pixelSize: Metrics.fontSmall
        Layout.fillWidth: true
        wrapMode: Text.Wrap
    }
    ComboBox {
        id: control
        objectName: root.objectName + "Input"
        model: root.options
        textRole: "label"
        valueRole: "value"
        currentIndex: Math.max(0, root.options.findIndex(option => option.value === root.value))
        Layout.fillWidth: true
        implicitHeight: Metrics.popupRowHeight
        Accessible.name: root.title
        onActivated: root.selected(currentValue)
        contentItem: Text {
            text: control.displayText
            textFormat: Text.PlainText
            color: Theme.text
            font.family: Metrics.fontFamily
            font.pixelSize: Metrics.fontBody
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
            leftPadding: Metrics.space12
            rightPadding: Metrics.space24
        }
        indicator: Text {
            x: control.width - width - Metrics.space12
            anchors.verticalCenter: parent.verticalCenter
            text: "⌄"
            color: Theme.text
            font.pixelSize: Metrics.iconMedium
        }
        background: Rectangle {
            radius: Metrics.space8
            color: Theme.controlBackground(Theme.surface0, control.hovered)
            border.width: Metrics.borderWidth
            border.color: control.activeFocus ? Theme.accent : Theme.surface1
        }
        delegate: ItemDelegate {
            required property var modelData
            required property int index
            width: control.width
            implicitHeight: Metrics.popupRowHeight
            highlighted: control.highlightedIndex === index
            contentItem: Text {
                text: modelData.label
                textFormat: Text.PlainText
                color: Theme.text
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.fontBody
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
            }
            background: Rectangle {
                color: Theme.controlBackground(Theme.accent, parent.hovered, parent.down, parent.highlighted)
                radius: Metrics.space8
            }
        }
        popup: Popup {
            y: control.height
            width: control.width
            padding: Metrics.space4
            implicitHeight: Math.min(contentItem.implicitHeight + 2 * padding, 220)
            contentItem: ListView {
                implicitHeight: contentHeight
                clip: true
                model: control.popup.visible ? control.delegateModel : null
                currentIndex: control.highlightedIndex
                ScrollBar.vertical: ScrollBar {}
            }
            background: Rectangle {
                radius: Metrics.space8
                color: Theme.withAlpha(Theme.base, Settings.surfaceOpacity)
                border.width: Metrics.borderWidth
                border.color: Theme.surface1
            }
        }
    }
}
