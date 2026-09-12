pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.components
import qs.core

PopupFrame {
    id: root
    required property string screenName
    property date shownMonth: new Date(clock.date.getFullYear(), clock.date.getMonth(), 1)
    readonly property var polishLocale: Qt.locale("pl_PL")

    function cellDate(index) {
        const firstDay = (shownMonth.getDay() + 6) % 7;
        return new Date(shownMonth.getFullYear(), shownMonth.getMonth(), index - firstDay + 1);
    }

    function sameDay(a, b) {
        return a.getFullYear() === b.getFullYear()
            && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
    }

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    ColumnLayout {
        width: parent.width
        spacing: Metrics.space12

        RowLayout {
            Layout.fillWidth: true

            Text {
                text: root.polishLocale.toString(clock.date, "dddd, d MMMM yyyy")
                color: Theme.text
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.fontTitle
                fontSizeMode: Text.HorizontalFit
                minimumPixelSize: Metrics.fontSmall
                font.weight: Font.Bold
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                Layout.alignment: Qt.AlignVCenter
            }

            Text {
                text: root.polishLocale.toString(clock.date, Settings.clockFormat)
                color: Theme.accent
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.fontTitle
                font.weight: Font.Bold
                horizontalAlignment: Text.AlignRight
                Layout.alignment: Qt.AlignVCenter
            }
        }

        RowLayout {
            Layout.fillWidth: true
            ActionButton {
                text: "‹"
                borderless: true
                implicitWidth: 40
                onClicked: root.shownMonth = new Date(root.shownMonth.getFullYear(), root.shownMonth.getMonth() - 1, 1)
            }
            Text {
                text: root.polishLocale.toString(root.shownMonth, "MMMM yyyy")
                color: Theme.text
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.fontTitle
                font.weight: Font.DemiBold
                horizontalAlignment: Text.AlignHCenter
                Layout.fillWidth: true
            }
            ActionButton {
                text: "›"
                borderless: true
                implicitWidth: 40
                onClicked: root.shownMonth = new Date(root.shownMonth.getFullYear(), root.shownMonth.getMonth() + 1, 1)
            }
        }

        GridLayout {
            columns: 7
            columnSpacing: Metrics.space4
            rowSpacing: Metrics.space4
            Layout.alignment: Qt.AlignHCenter

            Repeater {
                model: ["Pn", "Wt", "Śr", "Cz", "Pt", "So", "Nd"]
                Text {
                    required property string modelData
                    text: modelData
                    color: Theme.overlay1
                    font.family: Metrics.fontFamily
                    font.pixelSize: 10
                    horizontalAlignment: Text.AlignHCenter
                    Layout.preferredWidth: 43
                }
            }

            Repeater {
                model: 42
                Rectangle {
                    required property int index
                    readonly property date day: root.cellDate(index)
                    readonly property bool inMonth: day.getMonth() === root.shownMonth.getMonth()
                    readonly property bool today: root.sameDay(day, clock.date)
                    implicitWidth: 43
                    implicitHeight: 34
                    radius: 9
                    color: today ? Theme.controlBackground(Theme.accent, false, false, true) : "transparent"
                    Text {
                        anchors.centerIn: parent
                        text: parent.day.getDate()
                        color: parent.today ? Theme.accent : parent.inMonth ? Theme.text : Theme.overlay0
                        font.family: Metrics.fontFamily
                        font.pixelSize: Metrics.fontSmall
                        font.weight: parent.today ? Font.Bold : Font.Normal
                    }
                }
            }
        }
    }
}
