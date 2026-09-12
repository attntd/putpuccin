import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell.Services.UPower
import qs.components
import qs.core
import qs.services

PopupFrame {
    id: root
    required property string screenName

    function duration(seconds) {
        if (!seconds || seconds <= 0)
            return Strings.calculating;
        const hours = Math.floor(seconds / 3600);
        const minutes = Math.round((seconds % 3600) / 60);
        return hours > 0 ? hours + " godz. " + minutes + " min" : minutes + " min";
    }

    component ProfileChip: Button {
        id: chip

        required property int profileValue
        property string glyph: ""
        property string label: ""
        readonly property bool selected: PowerService.profile === profileValue

        implicitHeight: 32
        leftPadding: Metrics.space8
        rightPadding: Metrics.space8

        contentItem: RowLayout {
            spacing: Metrics.space4

            Text {
                text: chip.glyph
                color: chip.selected ? Theme.accent : Theme.subtext0
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.iconSmall
            }

            Text {
                text: chip.label
                color: chip.selected ? Theme.text : Theme.subtext0
                font.family: Metrics.fontFamily
                font.pixelSize: 10
                font.weight: chip.selected ? Font.DemiBold : Font.Normal
                elide: Text.ElideRight
                horizontalAlignment: Text.AlignHCenter
                Layout.fillWidth: true
            }
        }

        background: Rectangle {
            radius: 9
            color: Theme.controlBackground(chip.selected ? Theme.accent : Theme.text,
                chip.hovered || chip.visualFocus, chip.down, chip.selected)
            opacity: chip.enabled ? 1 : 0.38
        }

        onClicked: PowerService.setProfile(profileValue)
    }

    ColumnLayout {
        width: parent.width
        spacing: Metrics.space12

        RowLayout {
            visible: PowerService.batteryAvailable
            Layout.fillWidth: true

            Text {
                text: PowerService.charging ? Icons.batteryCharging : Icons.battery
                color: PowerService.percentage <= 15 && !PowerService.charging ? Theme.warning : Theme.accent
                font.family: Metrics.fontFamily
                font.pixelSize: 34
            }

            Text {
                text: PowerService.percentage + "%"
                color: Theme.text
                font.family: Metrics.fontFamily
                font.pixelSize: 24
                font.weight: Font.Bold
                Layout.alignment: Qt.AlignVCenter
            }

            Text {
                text: PowerService.fullyCharged ? Strings.charged
                    : PowerService.charging ? Strings.untilFull + ": " + root.duration(PowerService.timeRemaining)
                    : Strings.remaining + ": " + root.duration(PowerService.timeRemaining)
                color: Theme.subtext0
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.fontSmall
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignRight
                Layout.alignment: Qt.AlignVCenter
            }
        }

        Rectangle {
            visible: PowerService.batteryAvailable
            Layout.fillWidth: true
            implicitHeight: 8
            radius: 4
            color: Theme.controlBackground(Theme.text, true)
            Rectangle {
                width: parent.width * PowerService.percentage / 100
                height: parent.height
                radius: parent.radius
                color: Theme.controlBackground(PowerService.percentage <= 15 && !PowerService.charging
                    ? Theme.warning : Theme.accent, false, false, true)
                border.width: 0
            }
        }

        RowLayout {
            visible: !PowerService.batteryAvailable
            Layout.fillWidth: true
            Text {
                text: PowerService.profile === PowerProfile.Performance ? Icons.profilePerformance
                    : PowerService.profile === PowerProfile.PowerSaver ? Icons.profileSaver : Icons.profileBalanced
                color: Theme.accent
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.iconLarge
            }
            Text {
                text: Strings.noBattery
                color: Theme.subtext0
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.fontBody
                Layout.fillWidth: true
            }
        }

        RowLayout {
            visible: PowerService.healthAvailable
            Layout.fillWidth: true
            Text {
                text: Strings.health
                color: Theme.subtext0
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.fontSmall
            }
            Text {
                text: PowerService.health + "%"
                color: Theme.text
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.fontSmall
                horizontalAlignment: Text.AlignRight
                Layout.fillWidth: true
            }
        }

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 1
            color: Theme.controlBackground(Theme.text, true)
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Metrics.space6

            ProfileChip {
                profileValue: PowerProfile.PowerSaver
                glyph: Icons.profileSaver
                label: Strings.profileSaver
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                Layout.preferredWidth: 1
            }

            ProfileChip {
                profileValue: PowerProfile.Balanced
                glyph: Icons.profileBalanced
                label: Strings.profileBalanced
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                Layout.preferredWidth: 1
            }

            ProfileChip {
                profileValue: PowerProfile.Performance
                glyph: Icons.profilePerformance
                label: Strings.profilePerformance
                enabled: PowerService.performanceAvailable
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                Layout.preferredWidth: 1
            }
        }

        Text {
            visible: !PowerService.performanceAvailable
            text: Strings.performanceUnavailable
            color: Theme.subtext0
            font.family: Metrics.fontFamily
            font.pixelSize: 10
            wrapMode: Text.Wrap
            Layout.fillWidth: true
        }
    }
}
