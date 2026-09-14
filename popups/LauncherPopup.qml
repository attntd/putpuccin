pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.components
import qs.core
import qs.services
import "../modules/launcher"
import "../modules/launcher/LauncherQuery.js" as Query

PopupFrame {
    id: root

    required property string screenName
    signal searchFocusRequested()
    showBorder: false
    border.width: 0
    property real maximumHeight: 600
    readonly property string searchRoot: Quickshell.env("HOME") || "/tmp"
    property string chipMode: ""
    property bool navigating: false
    property bool pendingG: false
    property bool destroying: false
    property bool updateQueued: false
    property bool applicationRefreshPending: false
    property var fileResults: []
    property string pendingFileQuery: ""
    property string runningFileQuery: ""
    property int searchRevision: 0
    property int runningRevision: -1
    property string fileError: ""
    property int selectedResultIndex: -1
    property var applications: []
    readonly property var parsed: Query.parse(search.text)
    readonly property string mode: chipMode || parsed.mode
    readonly property string query: chipMode ? search.text.trim() : parsed.query
    readonly property bool hasInput: chipMode.length > 0 || search.text.trim().length > 0
    readonly property bool fileSearchPending: fileSearch.running || fileSearchDebounce.running
    readonly property int collapsedHeight: Metrics.controlHeight + padding * 2
    readonly property var results: Query.results(mode, query, applications,
        fileResults, ClipboardService.entries, LauncherHistory.entries)
    readonly property int resultCount: results.length
    readonly property int visibleResultCount: Math.min(resultCount, Metrics.launcherVisibleRows)
    readonly property bool historyView: mode === "recent" || (!query && (mode === "application" || mode === "file"))
    readonly property string errorMessage: fileError || (historyView ? LauncherHistory.errorMessage : "")
    readonly property real preferredHeight: collapsedHeight + (hasInput
        ? Metrics.space8 + Math.max(1, visibleResultCount) * Metrics.launcherRowHeight
            + Math.max(0, visibleResultCount - 1) * Metrics.space6
            + (errorStatus.visible ? Metrics.space8 + errorStatus.implicitHeight : 0) : 0)

    implicitHeight: Math.min(maximumHeight, preferredHeight)

    function modeLabel(value) {
        return ({ recent: Strings.launcherRecent, application: Strings.launcherApplications,
            file: Strings.launcherFiles, clipboard: Strings.launcherClipboard,
            command: Strings.launcherCommand })[value] || "";
    }

    function ensureSelection() {
        selectedResultIndex = resultCount ? Math.max(0, Math.min(selectedResultIndex, resultCount - 1)) : -1;
    }

    function revealSelection() {
        if (selectedResultIndex >= 0 && resultList.height > 0) {
            resultList.forceLayout();
            const item = resultList.itemAtIndex(selectedResultIndex);
            if (!item || item.y < resultList.contentY
                    || item.y + item.height > resultList.contentY + resultList.height)
                resultList.positionViewAtIndex(selectedResultIndex, ListView.Contain);
        }
    }

    function refreshApplications() {
        applications = Array.from(DesktopEntries.applications.values || []);
    }

    function queueUpdate(reloadApplications) {
        if (destroying) return;
        applicationRefreshPending = applicationRefreshPending || reloadApplications;
        if (updateQueued) return;
        updateQueued = true;
        const owner = root;
        // Coalesce model changes without a zero-duration QML Timer (which uses
        // Qt's animation driver). Capture the owner, not a soon-to-be-deleted method.
        Qt.callLater(() => {
            if (!owner || owner.destroying !== false) return;
            owner.updateQueued = false;
            if (owner.applicationRefreshPending) {
                owner.applicationRefreshPending = false;
                owner.refreshApplications();
                owner.queueUpdate(false);
                return;
            }
            owner.ensureSelection();
            owner.revealSelection();
        });
    }

    function moveSelection(offset) {
        if (!resultCount) return;
        selectedResultIndex = Math.max(0, Math.min(resultCount - 1, selectedResultIndex + offset));
    }

    function activateSelection() {
        activate(results[selectedResultIndex]);
    }

    function activate(result) {
        if (!result) return;
        if (result.kind === "application") {
            result.application.execute();
            LauncherHistory.record("application", result.id);
        } else if (result.kind === "file") {
            Quickshell.execDetached(["xdg-open", result.id]);
            LauncherHistory.record("file", result.id);
        } else if (result.kind === "clipboard") {
            if (!LauncherHistory.copyClipboard(result.id)) return;
        } else if (result.kind === "command") {
            // The command is intentionally interpreted only inside the user's shell.
            Quickshell.execDetached(Query.terminalArguments(result.id, Quickshell.env("SHELL")));
            LauncherHistory.record("command", result.id);
        }
        SurfaceManager.closeLauncher(screenName);
    }

    function focusSearch(selectAll) {
        navigating = false;
        pendingG = false;
        search.forceActiveFocus(Qt.TabFocusReason);
        if (selectAll === true) search.selectAll();
    }

    function handleKey(event) {
        if (event.key === Qt.Key_Escape) {
            if (!navigating && hasInput) {
                navigating = true;
                pendingG = false;
                root.forceActiveFocus(Qt.TabFocusReason);
                ensureSelection();
            } else SurfaceManager.closeLauncher(screenName);
            event.accepted = true;
            return;
        }
        if (event.modifiers & (Qt.AltModifier | Qt.MetaModifier)) return;
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (!event.isAutoRepeat) activateSelection();
        } else if (event.key === Qt.Key_Down) moveSelection(1);
        else if (event.key === Qt.Key_Up) moveSelection(-1);
        else if (!navigating) {
            if (event.key !== Qt.Key_Backspace || search.text.length || !chipMode) return;
            const prefix = Query.prefix(chipMode);
            chipMode = "";
            search.text = prefix;
            search.cursorPosition = search.text.length;
        } else {
            const ctrl = event.modifiers & Qt.ControlModifier;
            if (event.key === Qt.Key_Home) selectedResultIndex = resultCount ? 0 : -1;
            else if (event.key === Qt.Key_End || (event.key === Qt.Key_G
                    && (event.text === "G" || (event.modifiers & Qt.ShiftModifier))))
                selectedResultIndex = resultCount - 1;
            else if (event.key === Qt.Key_PageDown || (ctrl && (event.key === Qt.Key_D || event.key === Qt.Key_F)))
                moveSelection(Math.max(1, Math.floor(resultList.height / (Metrics.launcherRowHeight + Metrics.space6))));
            else if (event.key === Qt.Key_PageUp || (ctrl && (event.key === Qt.Key_U || event.key === Qt.Key_B)))
                moveSelection(-Math.max(1, Math.floor(resultList.height / (Metrics.launcherRowHeight + Metrics.space6))));
            else if (ctrl) return;
            else if (event.key === Qt.Key_J) moveSelection(1);
            else if (event.key === Qt.Key_K) moveSelection(-1);
            else if (event.key === Qt.Key_G) {
                if (pendingG) selectedResultIndex = resultCount ? 0 : -1;
                pendingG = !pendingG;
                event.accepted = true;
                return;
            } else if (event.key === Qt.Key_Slash || event.key === Qt.Key_I || event.key === Qt.Key_A) focusSearch();
            else if (event.text === ":") {
                chipMode = "";
                search.text = ":";
                focusSearch();
                search.cursorPosition = 1;
            } else {
                pendingG = false;
                return;
            }
        }
        pendingG = false;
        event.accepted = true;
    }

    function scheduleFileSearch() {
        searchRevision++;
        pendingFileQuery = (!mode || mode === "file") ? query : "";
        fileResults = [];
        fileError = "";
        fileSearchDebounce.stop();
        if (fileSearch.running) fileSearch.running = false;
        if (pendingFileQuery) fileSearchDebounce.restart();
    }

    function startPendingFileSearch() {
        if (fileSearch.running || fileSearchDebounce.running || !pendingFileQuery) return;
        runningFileQuery = pendingFileQuery;
        runningRevision = searchRevision;
        fileSearch.exec(["fd", "--type", "file", "--absolute-path", "--fixed-strings",
            "--ignore-case", "--no-ignore", "--one-file-system", "--max-results", "100",
            "--print0", "--", runningFileQuery, searchRoot]);
        fileDeadline.restart();
    }

    onModeChanged: scheduleFileSearch()
    onQueryChanged: {
        selectedResultIndex = 0;
        scheduleFileSearch();
    }
    // DesktopEntries can remove/reinsert rows in a single update. Clamp only
    // after that batch and the dependent resultCount binding have settled.
    onResultsChanged: queueUpdate(false)
    onSelectedResultIndexChanged: queueUpdate(false)
    onHeightChanged: queueUpdate(false)
    Keys.onShortcutOverride: event => { if (event.key === Qt.Key_Escape) event.accepted = true; }
    Keys.onPressed: event => handleKey(event)
    Component.onCompleted: {
        ClipboardService.rememberFocus();
        refreshApplications();
    }
    Component.onDestruction: {
        destroying = true;
        fileSearchDebounce.stop();
        pendingFileQuery = "";
        fileSearch.running = false;
    }

    Connections {
        target: DesktopEntries.applications
        function onValuesChanged() { root.queueUpdate(true); }
    }

    Timer { id: fileSearchDebounce; interval: 140; onTriggered: root.startPendingFileSearch() }
    Timer {
        id: fileDeadline
        interval: 3000
        onTriggered: {
            fileSearch.running = false;
            root.fileError = Strings.launcherSearchFailed;
        }
    }
    Process {
        id: fileSearch
        stdout: StdioCollector { id: fileOutput }
        stderr: StdioCollector {}
        onStarted: fileDeadline.restart()
        onExited: code => {
            fileDeadline.stop();
            if (root.runningRevision === root.searchRevision) {
                if (code === 0) root.fileResults = fileOutput.text.split("\0").filter(path => path.length > 0);
                else root.fileError = Strings.launcherSearchFailed;
            } else if (!root.destroying && root.pendingFileQuery && !fileSearchDebounce.running) {
                fileSearchDebounce.restart();
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: Metrics.space8
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: Metrics.controlHeight
            spacing: Metrics.space8
            Text {
                text: root.mode === "command" ? Icons.terminal : Icons.search
                color: Theme.subtext0
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.iconSmall
                Layout.leftMargin: Metrics.space12
            }
            Button {
                id: chip
                objectName: "launcherChip"
                visible: root.chipMode.length > 0
                text: root.modeLabel(root.chipMode)
                Accessible.name: text + ", " + Strings.launcherRemoveFilter
                padding: Metrics.space6
                contentItem: Text {
                    text: chip.text + " ×"
                    color: Theme.accent
                    font.family: Metrics.fontFamily
                    font.pixelSize: Metrics.fontSmall
                }
                background: Rectangle {
                    radius: Metrics.launcherChipRadius
                    color: Theme.controlBackground(Theme.accent, chip.hovered, chip.down, true)
                }
                onClicked: { root.chipMode = ""; root.focusSearch(); }
            }
            TextField {
                id: search
                objectName: "launcherSearch"
                placeholderText: root.mode === "command" ? Strings.launcherCommandHint
                    : root.chipMode ? Strings.search : Strings.searchApplicationsFilesClipboard
                color: Theme.text
                placeholderTextColor: Theme.overlay1
                selectionColor: Theme.accent
                selectedTextColor: Theme.crust
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.fontBody
                selectByMouse: true
                leftPadding: 0
                Layout.fillWidth: true
                Layout.preferredHeight: Metrics.controlHeight
                background: Item {}
                onActiveFocusChanged: if (activeFocus) { root.navigating = false; root.pendingG = false; }
                onTextEdited: {
                    const prefix = Query.parse(text);
                    if (!root.chipMode && prefix.committed) {
                        const mode = prefix.mode;
                        const tail = text.replace(/^:[afc!]?\s+/i, "");
                        root.chipMode = mode;
                        text = tail;
                        cursorPosition = text.length;
                    }
                }
                Keys.onPressed: event => root.handleKey(event)
                HoverHandler { cursorShape: Qt.IBeamCursor }
                TapHandler {
                    onTapped: { root.searchFocusRequested(); root.focusSearch(); }
                }
            }
        }
        ListView {
            id: resultList
            objectName: "launcherResults"
            visible: root.resultCount > 0
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: 0
            model: root.results
            // Selection belongs to the popup. Disable ListView's independent
            // current-item scrolling so it cannot race explicit containment.
            currentIndex: -1
            highlightFollowsCurrentItem: false
            spacing: Metrics.space6
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            keyNavigationEnabled: false
            ScrollBar.vertical: ScrollBar {
                id: scrollBar
                visible: size < 1
                policy: ScrollBar.AlwaysOn
                padding: Metrics.space2
                // A static thumb avoids the style's delayed fade surviving
                // focus changes and respects reduced motion without a timer.
                contentItem: Rectangle {
                    implicitWidth: Metrics.space4
                    implicitHeight: Metrics.space4
                    radius: Metrics.space2
                    color: scrollBar.pressed ? Theme.accent : Theme.overlay0
                }
                background: Item {}
            }
            delegate: LauncherResult {
                required property var modelData
                required property int index
                result: modelData
                selected: root.selectedResultIndex === index
                width: resultList.width - (scrollBar.visible ? scrollBar.width + Metrics.space4 : 0)
                onActivated: root.activate(modelData)
                onPointed: if (!root.navigating) root.selectedResultIndex = index
            }
        }
        Text {
            visible: root.hasInput && root.resultCount === 0
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: 0
            verticalAlignment: Text.AlignVCenter
            horizontalAlignment: Text.AlignHCenter
            text: root.fileSearchPending || (root.historyView && !LauncherHistory.ready) ? Strings.loading
                : root.mode === "command" ? Strings.launcherCommandHint
                : root.historyView ? Strings.launcherEmptyHistory : Strings.noResults
            color: Theme.subtext0
            font.family: Metrics.fontFamily
            font.pixelSize: Metrics.fontSmall
            elide: Text.ElideRight
        }
        Text {
            id: errorStatus
            visible: root.hasInput && root.errorMessage.length > 0
            text: root.errorMessage
            color: Theme.warning
            font.family: Metrics.fontFamily
            font.pixelSize: Metrics.fontSmall
            elide: Text.ElideRight
            Layout.fillWidth: true
        }
    }
}
