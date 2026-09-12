pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.core
import qs.components
import qs.services

AbstractButton {
    id: root
    required property var notification
    property bool toast: false
    property bool managedReveal: false
    property bool revealSelected: false
    property real stackRevealProgress: -1
    property bool expanded: false
    property bool controlsOpen: false
    readonly property bool keyboardFocusWithin: {
        const focused = root.Window.activeFocusItem;
        if (!focused || !focused.visualFocus)
            return false;
        for (let item = focused; item; item = item.parent) {
            if (item === root)
                return true;
        }
        return false;
    }
    readonly property bool controlsRevealed: (managedReveal ? revealSelected : controlsOpen)
        || root.keyboardFocusWithin
    readonly property bool expandable: expanded || summaryText.truncated || bodyText.truncated
    signal activated(string actionId)
    signal controlsRequested()
    function revealControls() {
        if (managedReveal) controlsRequested();
        else controlsOpen = true;
    }
    hoverEnabled: true
    activeFocusOnTab: true
    padding: Metrics.space12
    Accessible.name: (!controlsRevealed || (expandable && !expanded) ? Strings.notificationsExpand : Strings.notificationsOpen) + ": " + notification.summary
    onClicked: {
        if (!controlsRevealed) {
            revealControls();
            if (expandable && !expanded) expanded = true;
        } else if (expandable && !expanded)
            expanded = true;
        else
            activated("");
    }
    // Shared reveal progress must stay fractional; the layout's per-row
    // rounding must not change the total stack height during a handoff.
    implicitHeight: managedReveal && stackRevealProgress >= 0
        ? primaryContent.implicitHeight + actionReveal.implicitHeight + controlsReveal.implicitHeight + Metrics.space24
        : content.implicitHeight + Metrics.space24

    background: Rectangle {
        radius: Metrics.popupRadius - Metrics.space4
        color: root.toast ? Theme.withAlpha(Theme.base, Settings.surfaceOpacity)
            : Theme.controlBackground(Theme.text, root.controlsRevealed)
        border.width: 0
        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            color: Theme.controlBackground(Theme.text, root.toast && root.controlsRevealed)
        }
    }
    readonly property string iconSource: {
        const icon = notification.appIcon;
        if (!icon)
            return "";
        return icon.startsWith("/") ? "file://" + icon : icon.startsWith("file:") || icon.startsWith("image:") ? icon : Quickshell.iconPath(icon, true);
    }

    contentItem: ColumnLayout {
        id: content
        spacing: 0
        ColumnLayout {
            id: primaryContent
            Layout.fillWidth: true
            spacing: Metrics.space6
            RowLayout {
                Layout.fillWidth: true
                spacing: Metrics.space8
                Image {
                    visible: source.toString().length > 0 && status !== Image.Error
                    source: root.iconSource
                    sourceSize.width: 24
                    sourceSize.height: 24
                    Layout.preferredWidth: 24
                    Layout.preferredHeight: 24
                }
                Text {
                    text: root.notification.appName
                    textFormat: Text.PlainText
                    font.family: Metrics.fontFamily
                    font.pixelSize: Metrics.fontSmall
                    font.weight: Font.DemiBold
                    color: Theme.flamingo
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
                Text {
                    text: Qt.formatDateTime(new Date(root.notification.time), "dd.MM HH:mm")
                    color: Theme.subtext0
                    font.family: Metrics.fontFamily
                    font.pixelSize: Metrics.fontSmall
                }
                // Truncation determines whether the arrow is available. Keep
                // its width reserved: letting that same state change the header's
                // minimum width can make the pre-map layout alternate forever.
                Item {
                    Layout.preferredWidth: Metrics.minHitSize
                    Layout.preferredHeight: root.expandable ? Metrics.minHitSize : 0
                    ActionButton {
                        anchors.fill: parent
                        objectName: "notificationExpand"
                        visible: root.expandable
                        opacity: !root.toast || root.controlsRevealed ? 1 : 0
                        enabled: root.expandable && (!root.toast || root.controlsRevealed)
                        Behavior on opacity { NumberAnimation { duration: Motion.fast } }
                        glyph: root.expanded ? Icons.chevronUp : Icons.chevronDown
                        borderless: true
                        implicitWidth: Metrics.minHitSize
                        implicitHeight: Metrics.minHitSize
                        Accessible.name: root.expanded ? Strings.notificationsCollapse : Strings.notificationsExpand
                        onClicked: { root.revealControls(); root.expanded = !root.expanded; }
                    }
                }
            }
            NotificationText {
                id: summaryText
                objectName: "notificationSummary"
                visible: text.length > 0
                text: root.notification.summary
                color: Theme.text
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.fontBody
                font.weight: Font.DemiBold
                maximumLineCount: 3
                expanded: root.expanded
                Layout.fillWidth: true
            }
            NotificationText {
                id: bodyText
                objectName: "notificationBody"
                visible: text.length > 0
                text: root.notification.body
                color: Theme.subtext1
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.fontBody
                maximumLineCount: 5
                expanded: root.expanded
                Layout.fillWidth: true
            }
            Image {
                visible: source.toString().length > 0 && status !== Image.Error
                source: root.notification.image || ""
                sourceSize.width: 800
                sourceSize.height: 400
                fillMode: Image.PreserveAspectFit
                Layout.fillWidth: true
                Layout.preferredHeight: visible ? Math.min(140, implicitHeight) : 0
            }
        }
        RevealSection {
            id: actionReveal
            objectName: "notificationActions"
            topInset: Metrics.space8
            externalProgress: root.toast && root.managedReveal && root.stackRevealProgress >= 0
                ? (root.notification.actions || []).some(a => a.id !== "default" && a.id !== "inline-reply")
                    ? root.stackRevealProgress : 0
                : -1
            Layout.fillWidth: true
            revealed: (root.notification.actions || []).some(a => a.id !== "default" && a.id !== "inline-reply")
                && (!root.toast || root.controlsRevealed)
            Flow {
                width: parent.width
                spacing: Metrics.space6
                Repeater {
                    model: (root.notification.actions || []).filter(a => a.id !== "default" && a.id !== "inline-reply")
                    ActionButton {
                        required property var modelData
                        objectName: "notificationAction_" + modelData.id
                        text: modelData.text.length > 35 ? modelData.text.slice(0, 32) + "…" : modelData.text
                        borderless: true
                        onClicked: root.activated(modelData.id)
                    }
                }
            }
        }
        RevealSection {
            id: controlsReveal
            objectName: "notificationControls"
            topInset: Metrics.space8
            externalProgress: root.managedReveal ? root.stackRevealProgress : -1
            Layout.fillWidth: true
            revealed: root.controlsRevealed
            RowLayout {
                width: parent.width
                Item {
                    Layout.fillWidth: true
                }
                ActionButton {
                    visible: root.toast
                    objectName: "notificationClose"
                    text: Strings.close
                    borderless: true
                    onClicked: NotificationService.hideToast(root.notification.uid)
                }
                ActionButton {
                    id: discard
                    objectName: "notificationDiscard"
                    enabled: root.controlsRevealed
                    text: Strings.notificationsDiscard
                    destructive: true
                    borderless: true
                    onClicked: NotificationService.discard(root.notification.uid)
                }
            }
        }
    }
}
