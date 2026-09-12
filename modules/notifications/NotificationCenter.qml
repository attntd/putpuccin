pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.core
import qs.components
import qs.services

FocusScope {
    id: root
    required property string screenName
    property real maximumHeight: 600
    property var expandedGroups: ({})
    property bool confirmingClear: false
    property string clickedUid: ""
    property string keyboardUid: ""
    readonly property string selectedUid: keyboardUid || clickedUid
    readonly property var displayedUids: {
        const uids = [];
        for (const group of groups) {
            const records = expandedGroups[group.key] ? group.records : group.records.slice(0, 1);
            for (const record of records) uids.push(record.uid);
        }
        return uids;
    }
    signal searchFocusRequested()
    readonly property var groups: NotificationService.groups(search.text)
    readonly property bool hasHistory: NotificationService.count > 0
    implicitHeight: Math.min(maximumHeight, chrome.implicitHeight + (hasHistory ? Math.max(Metrics.minHitSize, list.contentHeight) + Metrics.space8 : empty.implicitHeight + Metrics.space8)
        + footer.implicitHeight + Metrics.space24)
    activeFocusOnTab: true
    Keys.onEscapePressed: SurfaceManager.closeOn(screenName)

    NotificationTransition {
        id: transition
        uids: root.displayedUids
    }
    onSelectedUidChanged: transition.select(selectedUid)
    onDisplayedUidsChanged: {
        if (displayedUids.indexOf(clickedUid) < 0) clickedUid = "";
        if (displayedUids.indexOf(keyboardUid) < 0) keyboardUid = "";
    }
    onVisibleChanged: if (!visible) {
        clickedUid = "";
        keyboardUid = "";
        transition.reset();
    }

    function toggleGroup(key) {
        const map = Object.assign({}, expandedGroups);
        map[key] = !map[key];
        expandedGroups = map;
    }
    function activate(uid, action) {
        SurfaceManager.closeOn(screenName);
        NotificationService.activate(uid, action);
    }
    onHasHistoryChanged: {
        if (!hasHistory) {
            search.text = "";
            confirmingClear = false;
        }
    }
    Component.onCompleted: {
        NotificationService.setCenterOpen(screenName, true);
        if (SurfaceManager.notificationsPinned(screenName))
            Qt.callLater(() => dndButton.forceActiveFocus());
    }
    Component.onDestruction: NotificationService.setCenterOpen(screenName, false)

    ColumnLayout {
        id: chrome
        x: Metrics.space8
        y: Metrics.space8
        width: root.width - Metrics.space16
        spacing: Metrics.space8
        RowLayout {
            Layout.fillWidth: true
            Text {
                text: Strings.notificationsDnd
                color: Theme.text
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.fontBody
                Layout.fillWidth: true
            }
            ActionButton {
                id: dndButton
                objectName: "notificationDnd"
                glyph: NotificationService.dnd ? Icons.notificationOff : Icons.notification
                destructive: NotificationService.dnd
                borderless: true
                implicitWidth: 42
                Accessible.name: Strings.notificationsDnd + ": "
                    + (NotificationService.dnd ? Strings.enabled : Strings.disabled)
                onClicked: NotificationService.toggleDnd()
            }
        }
        RowLayout {
            visible: root.hasHistory
            Layout.fillWidth: true
            SearchField {
                id: search
                objectName: "notificationSearch"
                onSearchFocusRequested: root.searchFocusRequested()
                Layout.fillWidth: true
                placeholderText: Strings.notificationsSearch
                onActiveFocusChanged: {
                    if (activeFocus && focusReason !== Qt.MouseFocusReason)
                        SurfaceManager.pinNotifications(root.screenName);
                }
                TapHandler {
                    onTapped: SurfaceManager.pinNotifications(root.screenName)
                }
            }
            ActionButton {
                objectName: "notificationClear"
                glyph: Icons.trash
                borderless: true
                destructive: true
                implicitWidth: 42
                Accessible.name: Strings.notificationsClear
                onClicked: root.confirmingClear = !root.confirmingClear
            }
        }
        RevealSection {
            objectName: "notificationClearConfirmation"
            revealed: root.confirmingClear && root.hasHistory
            Layout.fillWidth: true
            RowLayout {
                width: parent.width
                Text {
                    text: Strings.notificationsClearAction
                    color: Theme.text
                    font.family: Metrics.fontFamily
                    font.pixelSize: Metrics.fontSmall
                    Layout.fillWidth: true
                }
                ActionButton {
                    objectName: "notificationConfirmClear"
                    text: Strings.clear
                    destructive: true
                    borderless: true
                    onClicked: { root.confirmingClear = false; NotificationService.clearAll(); }
                }
                ActionButton {
                    objectName: "notificationCancelClear"
                    text: Strings.cancel
                    borderless: true
                    onClicked: root.confirmingClear = false
                }
            }
        }
        Text {
            visible: NotificationService.errorMessage.length > 0
            text: NotificationService.errorMessage
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            color: Theme.warning
            font.pixelSize: Metrics.fontSmall
            Layout.fillWidth: true
        }
    }
    Text {
        id: empty
        visible: !root.hasHistory
        anchors.top: chrome.bottom
        anchors.topMargin: Metrics.space8
        anchors.horizontalCenter: parent.horizontalCenter
        text: Strings.notificationsEmpty
        color: Theme.subtext0
        font.family: Metrics.fontFamily
        font.pixelSize: Metrics.fontBody
    }
    ListView {
        id: list
        objectName: "notificationList"
        visible: root.hasHistory
        x: Metrics.space8
        y: chrome.y + chrome.height + Metrics.space8
        width: root.width - Metrics.space16
        height: Math.max(0, root.height - y - footer.implicitHeight - Metrics.space16)
        model: root.groups
        spacing: Metrics.space12
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
        delegate: Item {
            id: group
            required property var modelData
            readonly property alias notificationCards: cards
            property Item lastCard: null
            implicitHeight: lastCard ? lastCard.y + lastCard.height : groupHeader.implicitHeight
            // Flush both sides of a handoff together, after their bindings
            // settle. Never enter ListView layout recursively during creation.
            onImplicitHeightChanged: Qt.callLater(list.forceLayout)
            width: list.width
            RowLayout {
                id: groupHeader
                width: parent.width
                Text {
                    text: group.modelData.name
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    color: Theme.subtext0
                    font.family: Metrics.fontFamily
                    font.pixelSize: Metrics.fontSmall
                    Layout.fillWidth: true
                }
                ActionButton {
                    visible: group.modelData.records.length > 1
                    text: root.expandedGroups[group.modelData.key] ? Strings.notificationsLess
                        : Strings.notificationsOlder + " (" + (group.modelData.records.length - 1) + ")"
                    borderless: true
                    implicitHeight: Metrics.minHitSize
                    onClicked: root.toggleGroup(group.modelData.key)
                }
            }
            Repeater {
                id: cards
                onItemAdded: (index, item) => { group.lastCard = item; }
                onItemRemoved: (index, item) => {
                    if (group.lastCard === item) group.lastCard = index > 0 ? itemAt(index - 1) : null;
                }
                model: root.expandedGroups[group.modelData.key] ? group.modelData.records : group.modelData.records.slice(0, 1)
                NotificationCard {
                    id: card
                    required property var modelData
                    required property int index
                    readonly property Item previousCard: index > 0 ? cards.itemAt(index - 1) : null
                    objectName: "notificationCard_" + modelData.uid
                    width: group.width
                    // Avoid a second, deferred Column layout between animated
                    // card heights and the ListView's group positions.
                    y: (previousCard ? previousCard.y + previousCard.height : groupHeader.implicitHeight) + Metrics.space6
                    notification: modelData
                    managedReveal: true
                    revealSelected: root.selectedUid === modelData.uid
                    stackRevealProgress: transition.value(modelData.uid)
                    onKeyboardFocusWithinChanged: {
                        if (keyboardFocusWithin) root.keyboardUid = modelData.uid;
                        else if (root.keyboardUid === modelData.uid) root.keyboardUid = "";
                    }
                    onControlsRequested: { root.keyboardUid = ""; root.clickedUid = modelData.uid; }
                    onActivated: actionId => root.activate(modelData.uid, actionId)
                }
            }
        }
        Text {
            visible: !root.groups.length && root.hasHistory
            anchors.top: parent.top
            anchors.horizontalCenter: parent.horizontalCenter
            text: Strings.noResults
            font.family: Metrics.fontFamily
            font.pixelSize: Metrics.fontBody
            color: Theme.subtext0
        }
    }
    ColumnLayout {
        id: footer
        x: Metrics.space8
        y: root.height - implicitHeight - Metrics.space8
        width: root.width - Metrics.space16
        spacing: Metrics.space8
        RowLayout {
            visible: NotificationService.canUndo
            Layout.fillWidth: true
            Text {
                text: Strings.notificationsDiscarded
                color: Theme.subtext0
                font.pixelSize: Metrics.fontSmall
                Layout.fillWidth: true
                elide: Text.ElideRight
            }
            ActionButton {
                text: Strings.notificationsUndo
                onClicked: NotificationService.undo()
            }
        }
    }
}
