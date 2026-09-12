pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.components
import qs.core
import qs.popups
import qs.services

Item {
    id: root

    // The title is its own hover target; launcher and media are sibling modules.
    property var barWindow
    property var shellScreen
    readonly property string screenName: HyprlandService.screenName(shellScreen)
    readonly property var toplevel: HyprlandService.activeToplevelFor(shellScreen)
    readonly property string applicationId: HyprlandService.contextApplicationId(root.toplevel)
    readonly property string windowIcon: !root.toplevel ? Icons.monitor
        : HyprlandService.isTerminal(root.toplevel) ? Icons.terminal
        : root.applicationId === "jellyfin" ? Icons.media
        : HyprlandService.isBrowser(root.toplevel) ? Icons.browser : Icons.window
    readonly property string windowIconSource: root.applicationId === "jellyfin" ? Icons.jellyfinSource : ""
    readonly property string windowTitle: HyprlandService.displayTitleFor(shellScreen)
        || (!root.toplevel ? Strings.desktop : root.applicationId ? ""
            : HyprlandService.toplevelClass(root.toplevel) || Strings.window)
    readonly property string windowHost: HyprlandService.terminalHostFor(shellScreen)
    readonly property string windowCommand: HyprlandService.terminalCommandFor(shellScreen)
    readonly property string windowPrefix: root.windowHost
        || (root.applicationId === "zen" ? Strings.zenBrowser
            : root.applicationId === "jellyfin" ? Strings.jellyfin : "")
    readonly property string windowDetails: [root.windowTitle, root.windowCommand].filter(value => value.length > 0).join(" · ")
    readonly property string expansionSurface: "window"
    readonly property int expansionWidth: 430
    readonly property Component expansionComponent: windowExpansion

    implicitWidth: content.implicitWidth + Metrics.space16
    implicitHeight: Metrics.controlHeight

    RowLayout {
        id: content
        anchors.fill: parent
        anchors.leftMargin: Metrics.space8
        anchors.rightMargin: Metrics.space8
        spacing: Metrics.space8

        Item {
            implicitWidth: root.applicationId === "jellyfin" ? Metrics.iconMedium : iconGlyph.implicitWidth
            implicitHeight: Metrics.iconMedium
            Layout.alignment: Qt.AlignVCenter
            Image {
                id: applicationIcon
                objectName: "contextApplicationIcon"
                anchors.fill: parent
                source: root.windowIconSource
                sourceSize.width: 2 * Metrics.iconMedium
                sourceSize.height: 2 * Metrics.iconMedium
                fillMode: Image.PreserveAspectFit
                visible: status === Image.Ready
            }
            Text {
                id: iconGlyph
                anchors.centerIn: parent
                visible: applicationIcon.status !== Image.Ready
                text: root.windowIcon
                color: Theme.accent
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.iconMedium
            }
        }

        Text {
            objectName: "contextPrefix"
            visible: root.windowPrefix.length > 0
            text: root.windowPrefix
            textFormat: Text.PlainText
            color: Theme.accent
            font.family: Metrics.fontFamily
            font.pixelSize: Metrics.fontSmall
            Layout.alignment: Qt.AlignVCenter
        }

        Text {
            objectName: "contextPrefixSeparator"
            visible: root.windowPrefix.length > 0 && root.windowDetails.length > 0
            text: "·"
            color: Theme.overlay1
            font.family: Metrics.fontFamily
            font.pixelSize: Metrics.fontSmall
            Layout.alignment: Qt.AlignVCenter
        }

        TypewriterText {
            objectName: "contextDetails"
            visible: root.windowDetails.length > 0
            sourceText: root.windowDetails
            contextKey: root.toplevel ? root.toplevel.address : "desktop"
            textFormat: Text.PlainText
            color: Theme.text
            font.family: Metrics.fontFamily
            font.pixelSize: Metrics.fontSmall
            Layout.alignment: Qt.AlignVCenter
        }

    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        onClicked: ModuleActions.run("context", "primary", root.screenName)
    }

    Component {
        id: windowExpansion
        WindowPopup {
            screenName: root.screenName
            shellScreen: root.shellScreen
            embedded: true
        }
    }
}
