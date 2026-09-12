import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.core

ColumnLayout {
    id: root
    property string title: ""
    property string hint: ""
    property alias text: input.text
    property alias placeholderText: input.placeholderText
    property alias input: input
    signal edited(string value)
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
    TextField {
        id: input
        objectName: root.objectName + "Input"
        Layout.fillWidth: true
        implicitHeight: Metrics.popupRowHeight
        maximumLength: 1024
        selectByMouse: true
        Accessible.name: root.title
        color: Theme.text
        selectionColor: Theme.accent
        selectedTextColor: Theme.crust
        placeholderTextColor: Theme.overlay1
        font.family: Metrics.fontFamily
        font.pixelSize: Metrics.fontBody
        onTextEdited: root.edited(text)
        background: Rectangle {
            radius: Metrics.space8
            color: Theme.controlBackground(Theme.surface0)
            border.width: Metrics.borderWidth
            border.color: input.activeFocus ? Theme.accent : Theme.surface1
        }
        onActiveFocusChanged: {
            if (activeFocus) Qt.callLater(() => input.ensureVisible());
        }
        function ensureVisible() {
            let item = input.parent;
            while (item && typeof item.ensureItemVisible !== "function") item = item.parent;
            if (item) item.ensureItemVisible(input);
        }
    }
    Text {
        visible: root.hint.length > 0
        text: root.hint
        textFormat: Text.PlainText
        color: Theme.subtext0
        font.family: Metrics.fontFamily
        font.pixelSize: Metrics.fontSmall
        wrapMode: Text.Wrap
        Layout.fillWidth: true
    }
}
