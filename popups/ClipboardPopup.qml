pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtQuick.Layouts
import qs.components
import qs.core
import qs.services

PopupFrame {
    id: root
    required property string screenName
    property bool confirmClear: false
    signal searchFocusRequested()

    Component.onCompleted: ClipboardService.refresh()
    Component.onDestruction: ClipboardService.query = ""

    ColumnLayout {
        width: parent.width
        spacing: Metrics.space8

        RowLayout {
            Layout.fillWidth: true
            SectionTitle { text: Strings.clipboard; Layout.fillWidth: true }
            ActionButton {
                text: ClipboardService.paused ? Strings.resume : Strings.pause
                borderless: true
                glyph: ClipboardService.paused ? Icons.play : Icons.pauseCircle
                implicitWidth: 96
                onClicked: ClipboardService.setPaused(!ClipboardService.paused)
            }
        }

        RowLayout {
            Layout.fillWidth: true
            SearchField {
                id: search
                objectName: "clipboardSearch"
                onSearchFocusRequested: root.searchFocusRequested()
                Layout.fillWidth: true
                onTextChanged: ClipboardService.query = text
            }
            ActionButton {
                text: ""
                glyph: Icons.trash
                borderless: true
                destructive: true
                implicitWidth: 42
                objectName: "clipboardClear"
                Accessible.name: Strings.clearClipboardAction
                onClicked: root.confirmClear = !root.confirmClear
            }
        }

        Item {
            visible: root.confirmClear
            implicitHeight: confirmRow.implicitHeight
            Layout.fillWidth: true

            RowLayout {
                id: confirmRow
                anchors.fill: parent
                Text {
                    text: Strings.clearClipboardAction
                    color: Theme.text
                    font.family: Metrics.fontFamily
                    font.pixelSize: Metrics.fontSmall
                    Layout.fillWidth: true
                }
                ActionButton {
                    text: Strings.clear; destructive: true
                    borderless: true
                    onClicked: { root.confirmClear = false; ClipboardService.wipe(); }
                }
                ActionButton { text: Strings.cancel; borderless: true; onClicked: root.confirmClear = false }
            }
        }

        Item {
            Layout.fillWidth: true
            Layout.preferredHeight: history.count === 0 ? 104
                : Math.min(history.count, 6) * 64

            ListView {
                id: history
                anchors.fill: parent
                model: ClipboardService.filteredEntries
                spacing: Metrics.space6
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                activeFocusOnTab: count > 0
                keyNavigationEnabled: true

                onActiveFocusChanged: {
                    if (activeFocus && currentIndex < 0 && count > 0)
                        currentIndex = 0;
                }
                Keys.onReturnPressed: {
                    if (currentItem)
                        currentItem.activate();
                }
                Keys.onEnterPressed: {
                    if (currentItem)
                        currentItem.activate();
                }
                Keys.onSpacePressed: {
                    if (currentItem)
                        currentItem.activate();
                }
                Keys.onDeletePressed: {
                    if (currentItem)
                        ClipboardService.remove(currentItem.modelData.id);
                }

                delegate: Rectangle {
                    id: entryDelegate
                    required property var modelData
                    required property int index
                    width: history.width
                    height: modelData.binary ? 84 : 58
                    radius: 10
                    color: Theme.controlBackground(Theme.text, entryMouse.containsMouse)
                    border.width: history.activeFocus && ListView.isCurrentItem ? 1 : 0
                    border.color: Theme.accent

                    function activate() {
                        ClipboardService.copy(entryDelegate.modelData.id);
                        SurfaceManager.closeOn(root.screenName);
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.margins: Metrics.space8
                        spacing: Metrics.space8

                        Rectangle {
                            visible: entryDelegate.modelData.binary
                            Layout.preferredWidth: 64
                            Layout.fillHeight: true
                            radius: 7
                            color: Theme.controlBackground(Theme.mantle)
                            clip: true

                            Image {
                                anchors.fill: parent
                                anchors.margins: 2
                                fillMode: Image.PreserveAspectFit
                                asynchronous: true
                                cache: true
                                sourceSize: Qt.size(
                                    Math.max(1, Math.ceil(width * (root.Window.window ? root.Window.window.devicePixelRatio : 1))),
                                    Math.max(1, Math.ceil(height * (root.Window.window ? root.Window.window.devicePixelRatio : 1))))
                                source: entryDelegate.modelData.thumbnail
                            }

                            Text {
                                anchors.centerIn: parent
                                visible: entryDelegate.modelData.thumbnail.length === 0
                                text: Icons.image
                                color: Theme.overlay1
                                font.family: Metrics.fontFamily
                                font.pixelSize: Metrics.iconLarge
                            }
                        }

                        Text {
                            text: entryDelegate.modelData.preview
                            color: Theme.text
                            font.family: Metrics.fontFamily
                            font.pixelSize: Metrics.fontSmall
                            elide: Text.ElideRight
                            wrapMode: Text.Wrap
                            maximumLineCount: entryDelegate.modelData.binary ? 2 : 3
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            verticalAlignment: Text.AlignVCenter
                        }

                        ActionButton {
                            text: ""
                            glyph: Icons.close
                            borderless: true
                            destructive: true
                            implicitWidth: 36
                            implicitHeight: 34
                            onClicked: ClipboardService.remove(entryDelegate.modelData.id)
                        }
                    }

                    MouseArea {
                        id: entryMouse
                        anchors.fill: parent
                        anchors.rightMargin: 44
                        hoverEnabled: true
                        onClicked: {
                            history.currentIndex = entryDelegate.index;
                            entryDelegate.activate();
                        }
                    }

                    Component.onCompleted: {
                        if (entryDelegate.modelData.binary && entryDelegate.modelData.thumbnail.length === 0)
                            ClipboardService.requestThumbnail(entryDelegate.modelData.id);
                    }
                }

                EmptyState {
                    anchors.centerIn: parent
                    width: parent.width - 40
                    visible: history.count === 0
                    icon: ClipboardService.state === "unavailable" ? Icons.warning : Icons.clipboard
                    title: ClipboardService.state === "loading" ? Strings.loading
                        : ClipboardService.query.length > 0 ? Strings.noResults : Strings.clipboardEmpty
                    detail: ClipboardService.errorMessage
                }
            }
        }

    }
}
