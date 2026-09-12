pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.core
import qs.components
import qs.services

PanelWindow {
    id: window
    readonly property string screenName: screen ? screen.name : ""
    readonly property var entries: NotificationService.visibleToasts.filter(t => t.screen === screenName)
    readonly property bool showUndo: NotificationService.canUndo && NotificationService.undoScreen === screenName
        && !SurfaceManager.isOpen("notifications", screenName)
    property string clickedUid: ""
    NotificationTransition {
        id: transition
        uids: window.entries.map(entry => entry.uid)
    }
    onClickedUidChanged: transition.select(clickedUid)

    onEntriesChanged: {
        if (!entries.some(entry => entry.uid === clickedUid)) clickedUid = "";
    }
    onVisibleChanged: if (!visible) {
        clickedUid = "";
        transition.reset();
    }
    anchors { top: true; right: true }
    margins.top: Settings.topMargin + Settings.barHeight + Metrics.space8
    margins.right: Settings.sideMargin
    implicitWidth: Math.min(Settings.notificationWidth, screen ? screen.width - Settings.sideMargin * 2 : Settings.notificationWidth)
    // Keep the Wayland buffer stable while a card expands. Resizing the native
    // surface every frame makes compositor geometry lag behind the QML layout.
    implicitHeight: screen ? screen.height - margins.top - Metrics.space16 : 800
    visible: entries.length > 0 || showUndo
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "quickshell-de:notifications"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    mask: Region { item: stack }

    Flickable {
        id: viewport
        // A moving clip edge cuts through the last card's antialiasing. Keep
        // the viewport fixed too; only the input region follows the cards.
        anchors.fill: parent
        contentHeight: stack.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: stack
            width: window.width
            spacing: Metrics.space8
            Repeater {
                id: cards
                model: window.entries
                NotificationCard {
                    id: toast
                    required property var modelData
                    notification: NotificationService.record(modelData.uid) || {uid: modelData.uid, appName: "", summary: "", body: "", time: 0, actions: []}
                    toast: true
                    managedReveal: true
                    revealSelected: window.clickedUid === modelData.uid
                    stackRevealProgress: transition.value(modelData.uid)
                    width: stack.width
                    onControlsRequested: window.clickedUid = modelData.uid
                    onActivated: actionId => NotificationService.activate(modelData.uid, actionId)
                    onControlsRevealedChanged: NotificationService.pauseToast(modelData.uid, controlsRevealed)
                }
            }
            Rectangle {
                visible: window.showUndo
                width: stack.width
                implicitHeight: Metrics.space16 + undoRow.implicitHeight
                radius: Metrics.popupRadius
                color: Theme.withAlpha(Theme.base, Settings.surfaceOpacity)
                RowLayout {
                    id: undoRow
                    anchors.fill: parent
                    anchors.margins: Metrics.space8
                    Text {
                        text: Strings.notificationsDiscarded
                        color: Theme.text
                        font.family: Metrics.fontFamily
                        font.pixelSize: Metrics.fontSmall
                        Layout.fillWidth: true
                    }
                    ActionButton { text: Strings.notificationsUndo; onClicked: NotificationService.undo() }
                }
            }
        }
    }
}
