pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import qs.components
import qs.core
import qs.services

PopupFrame {
    id: root

    required property string screenName
    signal searchFocusRequested()
    showBorder: false
    border.width: 0
    readonly property string searchRoot: Quickshell.env("HOME") || "/tmp"
    property var fileResults: []
    property string pendingFileQuery: ""
    property string runningFileQuery: ""
    property int selectedResultIndex: -1
    readonly property bool fileSearchPending: fileSearch.running || fileSearchDebounce.running
    readonly property int collapsedHeight: search.implicitHeight + padding * 2
    readonly property var filteredApplications: {
        const query = search.text.trim().toLocaleLowerCase();
        if (!query)
            return [];
        const values = DesktopEntries.applications.values || [];
        const matches = values.filter(entry => {
            return entry && !entry.noDisplay
                && root.applicationRelevance(entry, query) < 100;
        });
        matches.sort((a, b) => {
            const scoreDifference = root.applicationRelevance(a, query)
                - root.applicationRelevance(b, query);
            return scoreDifference !== 0 ? scoreDifference : a.name.localeCompare(b.name);
        });
        return matches.slice(0, 4);
    }
    readonly property var clipboardResults: {
        const query = search.text.trim().toLocaleLowerCase();
        if (!query)
            return [];
        return ClipboardService.entries.filter(entry =>
            entry.preview.toLocaleLowerCase().indexOf(query) >= 0).slice(0, 4);
    }
    readonly property int resultCount: filteredApplications.length + fileResults.length + clipboardResults.length

    function normalized(value) {
        return typeof value === "string" ? value.toLocaleLowerCase() : "";
    }

    function wordStartsWith(value, query) {
        return value.split(/[\s._\-/]+/).some(word => word.startsWith(query));
    }

    function applicationRelevance(application, query) {
        const name = root.normalized(application.name);
        const genericName = root.normalized(application.genericName);
        const comment = root.normalized(application.comment);
        const keywords = application.keywords
            ? application.keywords.join(" ").toLocaleLowerCase() : "";

        if (name === query)
            return 0;
        if (name.startsWith(query))
            return 1;
        if (root.wordStartsWith(name, query))
            return 2;
        if (name.indexOf(query) >= 0)
            return 3;
        if (genericName === query || genericName.startsWith(query))
            return 4;
        if (root.wordStartsWith(genericName, query))
            return 5;
        if (root.wordStartsWith(keywords, query))
            return 6;
        if (genericName.indexOf(query) >= 0 || keywords.indexOf(query) >= 0)
            return 7;
        if (comment.indexOf(query) >= 0)
            return 8;
        return 100;
    }

    function ensureSelection() {
        if (root.resultCount < 1) {
            root.selectedResultIndex = -1;
            return;
        }
        root.selectedResultIndex = Math.max(0,
            Math.min(root.selectedResultIndex, root.resultCount - 1));
    }

    function moveSelection(offset) {
        if (root.resultCount < 1)
            return;
        if (root.selectedResultIndex < 0) {
            root.selectedResultIndex = offset < 0 ? root.resultCount - 1 : 0;
            return;
        }
        root.selectedResultIndex = (root.selectedResultIndex + offset
            + root.resultCount) % root.resultCount;
    }

    function activateSelection() {
        if (root.selectedResultIndex < 0)
            return;
        if (root.selectedResultIndex < root.filteredApplications.length) {
            root.launch(root.filteredApplications[root.selectedResultIndex]);
            return;
        }
        const fileIndex = root.selectedResultIndex - root.filteredApplications.length;
        if (fileIndex < root.fileResults.length)
            root.openFile(root.fileResults[fileIndex]);
        else
            root.copyClipboard(root.clipboardResults[fileIndex - root.fileResults.length]);
    }

    function focusSearch() {
        search.forceActiveFocus();
        search.selectAll();
    }

    function launch(application) {
        if (!application)
            return;
        application.execute();
        SurfaceManager.closeLauncher(root.screenName);
    }

    function openFile(path) {
        if (!path)
            return;
        Quickshell.execDetached(["xdg-open", path]);
        SurfaceManager.closeLauncher(root.screenName);
    }

    function copyClipboard(entry) {
        if (!entry)
            return;
        ClipboardService.copy(entry.id);
        SurfaceManager.closeLauncher(root.screenName);
    }

    function scheduleFileSearch(query) {
        root.pendingFileQuery = query.trim();
        root.fileResults = [];
        fileSearchDebounce.stop();
        if (root.pendingFileQuery.length < 1) {
            if (fileSearch.running)
                fileSearch.running = false;
            return;
        }
        fileSearchDebounce.restart();
    }

    function startPendingFileSearch() {
        if (fileSearch.running || fileSearchDebounce.running
                || root.pendingFileQuery.length < 1)
            return;
        root.runningFileQuery = root.pendingFileQuery;
        fileSearch.exec([
            "fd", "--type", "file", "--absolute-path", "--fixed-strings",
            "--ignore-case", "--no-ignore", "--one-file-system",
            "--max-results", "5", "--print0", "--",
            root.runningFileQuery, root.searchRoot
        ]);
    }

    function fileName(path) {
        const slash = path.lastIndexOf("/");
        return slash >= 0 ? path.slice(slash + 1) : path;
    }

    onClipboardResultsChanged: root.ensureSelection()
    Component.onCompleted: ClipboardService.rememberFocus()

    onFilteredApplicationsChanged: root.ensureSelection()
    onFileResultsChanged: root.ensureSelection()

    Component.onDestruction: {
        root.pendingFileQuery = "";
        if (fileSearch.running)
            fileSearch.running = false;
    }

    Timer {
        id: fileSearchDebounce
        interval: 140
        onTriggered: {
            if (fileSearch.running)
                fileSearch.running = false;
            else
                root.startPendingFileSearch();
        }
    }

    Process {
        id: fileSearch
        stdout: StdioCollector { id: fileSearchOutput }
        onExited: exitCode => {
            const completedQuery = root.runningFileQuery;
            root.runningFileQuery = "";
            if (exitCode === 0 && completedQuery === root.pendingFileQuery
                    && completedQuery === search.text.trim()) {
                root.fileResults = fileSearchOutput.text.split("\0")
                    .filter(path => path.length > 0);
            }
            if (root.pendingFileQuery !== completedQuery)
                Qt.callLater(root.startPendingFileSearch);
        }
    }

    ColumnLayout {
        width: parent.width
        spacing: Metrics.space8

        TextField {
            id: search
            placeholderText: Strings.searchApplicationsFilesClipboard
            color: Theme.text
            placeholderTextColor: Theme.overlay1
            selectionColor: Theme.accent
            selectedTextColor: Theme.crust
            font.family: Metrics.fontFamily
            font.pixelSize: Metrics.fontBody
            leftPadding: 38
            Layout.fillWidth: true
            Component.onCompleted: root.scheduleFileSearch(text)
            onTextChanged: {
                root.selectedResultIndex = 0;
                root.scheduleFileSearch(text);
            }
            onAccepted: root.activateSelection()
            Keys.onDownPressed: event => {
                root.moveSelection(1);
                event.accepted = true;
            }
            Keys.onUpPressed: event => {
                root.moveSelection(-1);
                event.accepted = true;
            }

            background: Item {}

            HoverHandler {
                cursorShape: Qt.IBeamCursor
            }
            TapHandler {
                onTapped: {
                    root.searchFocusRequested();
                    search.forceActiveFocus(Qt.MouseFocusReason);
                }
            }

            Text {
                anchors.left: parent.left
                anchors.leftMargin: Metrics.space12
                anchors.verticalCenter: parent.verticalCenter
                text: Icons.search
                color: Theme.subtext0
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.iconSmall
            }
        }

        SectionTitle {
            visible: applicationList.count > 0
            text: Strings.applications
        }

        ListView {
            id: applicationList
            model: root.filteredApplications
            spacing: Metrics.space6
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            visible: count > 0
            Layout.fillWidth: true
            Layout.preferredHeight: count * 48 + Math.max(0, count - 1) * spacing

            delegate: Rectangle {
                id: applicationDelegate

                required property var modelData
                required property int index
                readonly property bool selected: root.selectedResultIndex === index
                width: ListView.view.width
                height: 48
                radius: 10
                color: selected ? Theme.controlBackground(Theme.accent, false, false, true)
                    : Theme.controlBackground(Theme.text, applicationMouse.containsMouse)
                border.width: 0

                function activate() {
                    applicationList.currentIndex = applicationDelegate.index;
                    root.launch(applicationDelegate.modelData);
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.margins: Metrics.space8
                    spacing: Metrics.space8

                    Item {
                        Layout.preferredWidth: Metrics.iconLarge
                        Layout.preferredHeight: Metrics.iconLarge

                        IconImage {
                            id: applicationIcon
                            anchors.fill: parent
                            source: applicationDelegate.modelData.id === "signal"
                                || applicationDelegate.modelData.id === "signal.desktop"
                                || applicationDelegate.modelData.icon === "signal-desktop"
                                ? Icons.signalSource
                                : applicationDelegate.modelData.icon
                                    ? Quickshell.iconPath(applicationDelegate.modelData.icon) : ""
                            implicitSize: Metrics.iconLarge
                        }

                        Text {
                            visible: applicationIcon.status !== Image.Ready
                            anchors.centerIn: parent
                            text: Icons.launcher
                            color: Theme.subtext0
                            font.family: Metrics.fontFamily
                            font.pixelSize: Metrics.iconMedium
                        }
                    }

                    ColumnLayout {
                        spacing: 0
                        Layout.fillWidth: true

                        Text {
                            text: applicationDelegate.modelData.name
                            color: Theme.text
                            font.family: Metrics.fontFamily
                            font.pixelSize: Metrics.fontSmall
                            font.weight: Font.DemiBold
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }

                        Text {
                            visible: text.length > 0
                            text: applicationDelegate.modelData.genericName
                                || applicationDelegate.modelData.comment || ""
                            color: Theme.subtext0
                            font.family: Metrics.fontFamily
                            font.pixelSize: 10
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                    }
                }

                MouseArea {
                    id: applicationMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onContainsMouseChanged: {
                        if (containsMouse)
                            root.selectedResultIndex = applicationDelegate.index;
                    }
                    onClicked: applicationDelegate.activate()
                }
            }
        }

        RowLayout {
            visible: search.text.trim().length >= 1
                && (fileList.count > 0 || root.fileSearchPending)
            Layout.fillWidth: true

            SectionTitle {
                text: Strings.files
                Layout.fillWidth: true
            }

            Text {
                visible: root.fileSearchPending
                text: Strings.searchingFiles
                color: Theme.subtext0
                font.family: Metrics.fontFamily
                font.pixelSize: 10
            }
        }

        ListView {
            id: fileList
            model: root.fileResults
            spacing: Metrics.space6
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            visible: count > 0
            Layout.fillWidth: true
            Layout.preferredHeight: count * 48 + Math.max(0, count - 1) * spacing

            delegate: Rectangle {
                id: fileDelegate

                required property string modelData
                required property int index
                readonly property int resultIndex: root.filteredApplications.length + index
                readonly property bool selected: root.selectedResultIndex === resultIndex
                width: ListView.view.width
                height: 48
                radius: 10
                color: selected ? Theme.controlBackground(Theme.accent, false, false, true)
                    : Theme.controlBackground(Theme.text, fileMouse.containsMouse)
                border.width: 0

                function activate() {
                    fileList.currentIndex = fileDelegate.index;
                    root.openFile(fileDelegate.modelData);
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.margins: Metrics.space8
                    spacing: Metrics.space8

                    Text {
                        text: Icons.file
                        color: Theme.subtext0
                        font.family: Metrics.fontFamily
                        font.pixelSize: Metrics.iconMedium
                    }

                    ColumnLayout {
                        spacing: 0
                        Layout.fillWidth: true

                        Text {
                            text: root.fileName(fileDelegate.modelData)
                            color: Theme.text
                            font.family: Metrics.fontFamily
                            font.pixelSize: Metrics.fontSmall
                            font.weight: Font.DemiBold
                            elide: Text.ElideMiddle
                            Layout.fillWidth: true
                        }

                        Text {
                            text: fileDelegate.modelData
                            color: Theme.subtext0
                            font.family: Metrics.fontFamily
                            font.pixelSize: 10
                            elide: Text.ElideMiddle
                            Layout.fillWidth: true
                        }
                    }
                }

                MouseArea {
                    id: fileMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onContainsMouseChanged: {
                        if (containsMouse)
                            root.selectedResultIndex = fileDelegate.resultIndex;
                    }
                    onClicked: fileDelegate.activate()
                }
            }
        }

        SectionTitle {
            visible: clipboardList.count > 0
            text: Strings.clipboard
        }

        ListView {
            id: clipboardList
            model: root.clipboardResults
            spacing: Metrics.space6
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            visible: count > 0
            Layout.fillWidth: true
            Layout.preferredHeight: count * 48 + Math.max(0, count - 1) * spacing

            delegate: Rectangle {
                id: clipboardDelegate
                required property var modelData
                required property int index
                readonly property int resultIndex: root.filteredApplications.length + root.fileResults.length + index
                readonly property bool selected: root.selectedResultIndex === resultIndex
                width: ListView.view.width
                height: 48
                radius: 10
                color: selected ? Theme.controlBackground(Theme.accent, false, false, true)
                    : Theme.controlBackground(Theme.text, clipboardMouse.containsMouse)
                border.width: 0
                RowLayout {
                    anchors.fill: parent
                    anchors.margins: Metrics.space8
                    spacing: Metrics.space8
                    Text {
                        text: clipboardDelegate.modelData.binary ? Icons.image : Icons.clipboard
                        color: Theme.text
                        font.family: Metrics.fontFamily
                        font.pixelSize: Metrics.iconMedium
                    }
                    Text {
                        text: clipboardDelegate.modelData.preview
                        textFormat: Text.PlainText
                        color: Theme.text
                        font.family: Metrics.fontFamily
                        font.pixelSize: Metrics.fontSmall
                        elide: Text.ElideRight
                        maximumLineCount: 2
                        wrapMode: Text.Wrap
                        Layout.fillWidth: true
                    }
                }
                MouseArea {
                    id: clipboardMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onContainsMouseChanged: {
                        if (containsMouse)
                            root.selectedResultIndex = clipboardDelegate.resultIndex;
                    }
                    onClicked: root.copyClipboard(clipboardDelegate.modelData)
                }
            }
        }

        EmptyState {
            visible: search.text.trim().length >= 1
                && applicationList.count === 0 && fileList.count === 0 && clipboardList.count === 0
                && !root.fileSearchPending
            Layout.fillWidth: true
            icon: Icons.search
            title: Strings.noResults
        }
    }
}
