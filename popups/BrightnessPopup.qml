import QtQuick
import QtQuick.Layouts
import qs.components
import qs.core
import qs.services

PopupFrame {
    id: root
    required property string screenName

    ColumnLayout {
        width: parent.width
        spacing: Metrics.space12

        RowLayout {
            Layout.fillWidth: true
            Text {
                text: Icons.brightness
                color: Theme.accent
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.iconLarge
            }
            StatusSlider {
                from: 1
                to: 100
                stepSize: 0
                value: BrightnessService.sliderPercentage
                enabled: BrightnessService.available
                Layout.fillWidth: true
                onMoved: BrightnessService.setPercentage(value)
            }
            Text {
                text: Math.round(BrightnessService.percentage) + "%"
                color: Theme.text
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.fontSmall
                Layout.preferredWidth: 42
            }
        }
        Text {
            visible: BrightnessService.errorMessage.length > 0
            text: BrightnessService.errorMessage
            color: Theme.error
            font.family: Metrics.fontFamily
            font.pixelSize: Metrics.fontSmall
            wrapMode: Text.Wrap
            Layout.fillWidth: true
        }
    }
}
