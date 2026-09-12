pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.components
import qs.core
import "SelectionGeometry.js" as Geometry

PanelWindow {
    id: root

    required property var shellScreen
    required property var controller
    readonly property string screenName: shellScreen ? shellScreen.name : ""
    readonly property var snapshot: controller.screens.find(entry => entry.name === screenName) || null
    readonly property bool ownsFocus: controller.screenName === screenName
    readonly property bool interactive: controller.phase === "selecting" || controller.phase === "error"
    readonly property bool selectedHere: controller.hasSelection
        && controller.selection.screenName === screenName
    readonly property var screenWindows: controller.windows.filter(entry => entry.screenName === screenName)
    readonly property var committedRect: selectedHere
        ? Geometry.clipped(controller.selection, canvas.width, canvas.height) : null
    readonly property var hoveredRect: hoveredWindow
        ? Geometry.clipped(hoveredWindow, canvas.width, canvas.height) : null
    readonly property bool showHoverCandidate: interactive && controller.mode === "window"
        && selectedHere && !!hoveredRect && hoveredRect.width > 0 && hoveredRect.height > 0
        && (hoveredRect.x !== committedRect.x || hoveredRect.y !== committedRect.y
            || hoveredRect.width !== committedRect.width || hoveredRect.height !== committedRect.height)
    readonly property var previewRect: dragging ? dragRect
        : committedRect || (controller.mode === "window" && hoveredWindow
            ? Geometry.clipped(hoveredWindow, canvas.width, canvas.height)
            : controller.mode === "monitor" && ownsFocus
                ? { x: 0, y: 0, width: canvas.width, height: canvas.height } : null)
    readonly property bool hasPreview: !!previewRect && previewRect.width > 0 && previewRect.height > 0
    readonly property var previewPixels: snapshot && hasPreview
        ? Geometry.pixels(previewRect, snapshot) : { width: 0, height: 0 }
    readonly property string modeHint: controller.mode === "window"
        ? (screenWindows.length > 0 ? Strings.screenshotWindowHint : Strings.screenshotNoWindows)
        : controller.mode === "monitor" ? Strings.screenshotMonitorHint : Strings.screenshotRegionHint
    readonly property string selectionHint: controller.mode === "window" ? Strings.screenshotWindowKeyboardHint
        : controller.mode === "monitor" ? Strings.screenshotMonitorKeyboardHint : Strings.screenshotSelectionHint

    property bool frameReported: false
    Connections {
        target: root.contentItem.Window.window
        function onFrameSwapped() {
            if (!root.frameReported && frozenImage.status === Image.Ready) {
                root.frameReported = true;
                root.controller.presented(root.screenName);
            }
        }
    }

    property bool dragging: false
    property real dragStartX: 0
    property real dragStartY: 0
    property var dragRect: null
    property var hoveredWindow: null
    property string chosenWindowId: ""

    objectName: "screenshotOverlay"
    screen: shellScreen
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: Theme.base
    visible: controller.active && !!snapshot && frozenImage.status === Image.Ready
    WlrLayershell.namespace: "quickshell-de:screenshot"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: ownsFocus ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    function focusCanvas() {
        if (visible && ownsFocus)
            canvas.forceActiveFocus(Qt.OtherFocusReason);
    }

    function failSurface() {
        if (controller.active)
            controller.fail(Strings.screenshotCaptureFailed);
    }

    function checkImage() {
        if (controller.active && frozenImage.status === Image.Error)
            failSurface();
    }

    function setMode(mode) {
        if (!interactive)
            return;
        dragging = false;
        dragRect = null;
        hoveredWindow = null;
        chosenWindowId = "";
        controller.focusScreen(screenName);
        controller.setMode(mode);
        if (mode === "monitor")
            controller.selectMonitor(screenName);
        focusCanvas();
    }

    function perform(action) {
        if (!interactive || !selectedHere || (action === "edit" && !controller.editorAvailable))
            return;
        controller.perform(action);
    }

    function chooseWindow(entry) {
        if (!entry)
            return;
        chosenWindowId = String(entry.id);
        hoveredWindow = entry;
        controller.focusScreen(screenName);
        controller.selectWindow(entry.id);
    }

    function adjustSelection(dx, dy, resize) {
        if (!interactive)
            return;
        if (controller.mode === "window") {
            if (screenWindows.length === 0)
                return;
            let index = screenWindows.findIndex(entry => String(entry.id) === chosenWindowId);
            if (index < 0 && selectedHere) {
                index = screenWindows.findIndex(entry => {
                    const rect = Geometry.clipped(entry, canvas.width, canvas.height);
                    return rect.x === committedRect.x && rect.y === committedRect.y
                        && rect.width === committedRect.width && rect.height === committedRect.height;
                });
            }
            const direction = dx + dy > 0 ? 1 : -1;
            index = index < 0 ? (direction > 0 ? 0 : screenWindows.length - 1)
                : (index + direction + screenWindows.length) % screenWindows.length;
            chooseWindow(screenWindows[index]);
        } else if (controller.mode === "monitor") {
            const screens = controller.screens;
            if (screens.length === 0)
                return;
            const index = screens.findIndex(entry => entry.name === screenName);
            const direction = dx + dy > 0 ? 1 : -1;
            const next = screens[(index + direction + screens.length) % screens.length];
            controller.focusScreen(next.name);
            controller.selectMonitor(next.name);
        } else {
            const next = Geometry.adjust(committedRect, dx, dy, resize, canvas.width, canvas.height);
            controller.selectRegion(screenName, next.x, next.y, next.width, next.height);
        }
    }

    onOwnsFocusChanged: if (ownsFocus) Qt.callLater(focusCanvas)
    onVisibleChanged: if (visible) Qt.callLater(focusCanvas)
    onClosed: failSurface()
    onResourcesLost: failSurface()
    Component.onCompleted: Qt.callLater(focusCanvas)

    FocusScope {
        id: canvas
        objectName: "screenshotCanvas"
        anchors.fill: parent
        focus: true

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Escape) {
                root.controller.cancel();
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                    || (event.key === Qt.Key_C && (event.modifiers & Qt.ControlModifier))) {
                root.perform("copy");
            } else if (event.key === Qt.Key_S && (event.modifiers & Qt.ControlModifier)) {
                root.perform("save");
            } else if (event.key === Qt.Key_E && event.modifiers === Qt.NoModifier) {
                root.perform("edit");
            } else if (event.key >= Qt.Key_1 && event.key <= Qt.Key_3) {
                root.setMode(["region", "window", "monitor"][event.key - Qt.Key_1]);
            } else if ([Qt.Key_Left, Qt.Key_Right, Qt.Key_Up, Qt.Key_Down].indexOf(event.key) >= 0) {
                root.adjustSelection(event.key === Qt.Key_Left ? -1 : event.key === Qt.Key_Right ? 1 : 0,
                    event.key === Qt.Key_Up ? -1 : event.key === Qt.Key_Down ? 1 : 0,
                    !!(event.modifiers & Qt.ShiftModifier));
            } else {
                return;
            }
            event.accepted = true;
        }

        Image {
            id: frozenImage
            objectName: "screenshotFrozenImage"
            anchors.fill: parent
            source: root.snapshot ? root.snapshot.url : ""
            fillMode: Image.Stretch
            cache: false
            asynchronous: true
            onStatusChanged: if (status === Image.Error) Qt.callLater(root.checkImage)
        }

        // Four simple quads leave the selected pixels unchanged. No shader,
        // second screenshot texture, or continuously updating screencopy view.
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            height: root.hasPreview ? root.previewRect.y : parent.height
            color: Theme.launcherBackdrop
        }
        Rectangle {
            visible: root.hasPreview
            x: 0
            y: root.hasPreview ? root.previewRect.y : 0
            width: root.hasPreview ? root.previewRect.x : 0
            height: root.hasPreview ? root.previewRect.height : 0
            color: Theme.launcherBackdrop
        }
        Rectangle {
            visible: root.hasPreview
            x: root.hasPreview ? root.previewRect.x + root.previewRect.width : 0
            y: root.hasPreview ? root.previewRect.y : 0
            width: parent.width - x
            height: root.hasPreview ? root.previewRect.height : 0
            color: Theme.launcherBackdrop
        }
        Rectangle {
            visible: root.hasPreview
            x: 0
            y: root.hasPreview ? root.previewRect.y + root.previewRect.height : 0
            width: parent.width
            height: parent.height - y
            color: Theme.launcherBackdrop
        }

        Rectangle {
            id: selectionBorder
            objectName: "screenshotSelection"
            visible: root.hasPreview
            x: root.hasPreview ? root.previewRect.x : 0
            y: root.hasPreview ? root.previewRect.y : 0
            width: root.hasPreview ? root.previewRect.width : 0
            height: root.hasPreview ? root.previewRect.height : 0
            color: Theme.withAlpha(Theme.base, 0)
            border.width: Metrics.screenshotSelectionBorderWidth
            border.color: Theme.accent

            Repeater {
                model: root.controller.mode === "region" ? 4 : 0
                Rectangle {
                    required property int index
                    width: Metrics.screenshotSelectionHandleSize
                    height: width
                    x: index % 2 ? selectionBorder.width - width : 0
                    y: index > 1 ? selectionBorder.height - height : 0
                    color: Theme.accent
                }
            }
        }

        // Hover is a candidate, separate from the committed screenshot target.
        // Enter/Copy always acts on the strong mauve selection until a click.
        Rectangle {
            id: hoverBorder
            objectName: "screenshotWindowHover"
            visible: root.showHoverCandidate
            x: root.hoveredRect ? root.hoveredRect.x : 0
            y: root.hoveredRect ? root.hoveredRect.y : 0
            width: root.hoveredRect ? root.hoveredRect.width : 0
            height: root.hoveredRect ? root.hoveredRect.height : 0
            color: Theme.withAlpha(Theme.text, 0)
            border.width: Metrics.borderWidth
            border.color: Theme.text
        }

        MouseArea {
            id: selectionMouse
            objectName: "screenshotSelectionMouse"
            anchors.fill: parent
            enabled: root.interactive
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            cursorShape: root.controller.mode === "region" ? Qt.CrossCursor : Qt.PointingHandCursor
            onEntered: {
                root.controller.focusScreen(root.screenName);
                root.focusCanvas();
            }
            onExited: if (!root.dragging) root.hoveredWindow = null
            onPressed: mouse => {
                if (mouse.button === Qt.RightButton) {
                    root.controller.cancel();
                    return;
                }
                root.controller.focusScreen(root.screenName);
                root.focusCanvas();
                if (root.controller.mode === "region") {
                    root.dragStartX = mouse.x;
                    root.dragStartY = mouse.y;
                    root.dragRect = Geometry.fromPoints(mouse.x, mouse.y, mouse.x, mouse.y,
                        canvas.width, canvas.height);
                    root.dragging = true;
                } else if (root.controller.mode === "window") {
                    root.chooseWindow(Geometry.hitWindow(root.screenWindows, mouse.x, mouse.y));
                } else {
                    root.controller.selectMonitor(root.screenName);
                }
            }
            onPositionChanged: mouse => {
                if (root.dragging) {
                    root.dragRect = Geometry.fromPoints(root.dragStartX, root.dragStartY, mouse.x, mouse.y,
                        canvas.width, canvas.height);
                } else if (root.controller.mode === "window") {
                    root.hoveredWindow = Geometry.hitWindow(root.screenWindows, mouse.x, mouse.y);
                }
            }
            onReleased: mouse => {
                if (!root.dragging || mouse.button !== Qt.LeftButton)
                    return;
                const selected = Geometry.fromPoints(root.dragStartX, root.dragStartY, mouse.x, mouse.y,
                    canvas.width, canvas.height);
                root.dragging = false;
                root.dragRect = null;
                if (selected.width >= 1 && selected.height >= 1)
                    root.controller.selectRegion(root.screenName, selected.x, selected.y,
                        selected.width, selected.height);
            }
            onCanceled: {
                root.dragging = false;
                root.dragRect = null;
            }
        }

        Rectangle {
            id: dimensions
            objectName: "screenshotDimensions"
            visible: root.hasPreview
            x: root.hasPreview ? Geometry.clamp(root.previewRect.x, Metrics.space8,
                Math.max(Metrics.space8, canvas.width - width - Metrics.space8)) : 0
            y: root.hasPreview ? (root.previewRect.y >= height + Metrics.space8
                ? root.previewRect.y - height - Metrics.space4
                : root.previewRect.y + Metrics.space8) : 0
            width: dimensionText.implicitWidth + Metrics.space16
            height: dimensionText.implicitHeight + Metrics.space8
            radius: Metrics.space6
            color: Theme.withAlpha(Theme.base, Settings.surfaceOpacity)
            border.width: Metrics.borderWidth
            border.color: Theme.withAlpha(Theme.accent, 0.55)

            Text {
                id: dimensionText
                anchors.centerIn: parent
                text: Strings.screenshotPixels(root.previewPixels.width, root.previewPixels.height)
                color: Theme.text
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.fontSmall
                Accessible.name: text
            }
        }

        Rectangle {
            id: windowHoverLabel
            objectName: "screenshotWindowHoverLabel"
            visible: root.showHoverCandidate
            x: root.hoveredRect ? Geometry.clamp(root.hoveredRect.x + Metrics.space8, Metrics.space8,
                Math.max(Metrics.space8, canvas.width - width - Metrics.space8)) : 0
            y: root.hoveredRect ? Geometry.clamp(root.hoveredRect.y + root.hoveredRect.height - height - Metrics.space8,
                Metrics.space8, Math.max(Metrics.space8, canvas.height - height - Metrics.space8)) : 0
            width: Math.min(windowHoverText.implicitWidth + Metrics.space16, canvas.width - Metrics.space16)
            height: windowHoverText.implicitHeight + Metrics.space8
            radius: Metrics.space6
            color: Theme.withAlpha(Theme.base, Settings.surfaceOpacity)
            border.width: Metrics.borderWidth
            border.color: Theme.surface2

            Text {
                id: windowHoverText
                anchors.fill: parent
                anchors.leftMargin: Metrics.space8
                anchors.rightMargin: Metrics.space8
                verticalAlignment: Text.AlignVCenter
                text: (root.hoveredWindow ? root.hoveredWindow.title : "")
                    + " · " + Strings.screenshotWindowHoverHint
                textFormat: Text.PlainText
                color: Theme.text
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.fontSmall
                elide: Text.ElideRight
                Accessible.name: text
            }
            HoverHandler { id: windowTitleHover }
            ToolTip.visible: windowTitleHover.hovered && windowHoverText.truncated
            ToolTip.text: windowHoverText.text
        }

        Rectangle {
            id: controls
            objectName: "screenshotToolbar"
            readonly property var position: Geometry.toolbarPosition(root.committedRect, width, height,
                canvas.width, canvas.height, Metrics.space16)
            visible: root.ownsFocus && !root.dragging
            x: position.x
            y: position.y
            width: Math.min(Metrics.screenshotToolbarMaximumWidth, canvas.width - Metrics.space16 * 2,
                Math.max(modeButtons.implicitWidth, actionButtons.implicitWidth) + Metrics.space24)
            height: contents.implicitHeight + Metrics.space24
            radius: Metrics.popupRadius
            color: Theme.withAlpha(Theme.base, Settings.surfaceOpacity)
            border.width: Metrics.borderWidth
            border.color: Theme.withAlpha(Theme.surface2, 0.9)

            // Prevent a click in panel padding from starting a new capture.
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onPressed: mouse => mouse.accepted = true
            }

            ColumnLayout {
                id: contents
                anchors.fill: parent
                anchors.margins: Metrics.space12
                spacing: Metrics.space8

                GridLayout {
                    id: modeButtons
                    objectName: "screenshotModes"
                    Layout.fillWidth: true
                    columns: canvas.width < 520 ? 2 : 4
                    columnSpacing: Metrics.space6
                    rowSpacing: Metrics.space6

                    ActionButton {
                        objectName: "screenshotModeRegion"
                        Layout.fillWidth: true
                        text: Strings.screenshotRegion
                        glyph: Icons.screenshotRegion
                        accent: root.controller.mode === "region"
                        enabled: root.interactive
                        onClicked: root.setMode("region")
                        Accessible.name: text
                        ToolTip.visible: hovered
                        ToolTip.text: text + " · 1"
                    }
                    ActionButton {
                        objectName: "screenshotModeWindow"
                        Layout.fillWidth: true
                        text: Strings.screenshotWindow
                        glyph: Icons.window
                        accent: root.controller.mode === "window"
                        enabled: root.interactive
                        onClicked: root.setMode("window")
                        Accessible.name: text
                        ToolTip.visible: hovered
                        ToolTip.text: text + " · 2"
                    }
                    ActionButton {
                        objectName: "screenshotModeMonitor"
                        Layout.fillWidth: true
                        text: Strings.screenshotMonitor
                        glyph: Icons.monitor
                        accent: root.controller.mode === "monitor"
                        enabled: root.interactive
                        onClicked: root.setMode("monitor")
                        Accessible.name: text
                        ToolTip.visible: hovered
                        ToolTip.text: text + " · 3"
                    }
                    ActionButton {
                        objectName: "screenshotCancel"
                        Layout.fillWidth: true
                        text: Strings.cancel
                        glyph: Icons.close
                        onClicked: root.controller.cancel()
                        Accessible.name: text
                        ToolTip.visible: hovered
                        ToolTip.text: text + " · Esc"
                    }
                }

                Text {
                    id: hint
                    objectName: "screenshotHint"
                    Layout.fillWidth: true
                    text: !root.interactive ? Strings.screenshotWorking
                        : root.selectedHere ? root.selectionHint : root.modeHint
                    color: Theme.subtext1
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    font.family: Metrics.fontFamily
                    font.pixelSize: Metrics.fontSmall
                }

                GridLayout {
                    id: actionButtons
                    objectName: "screenshotActions"
                    visible: root.selectedHere
                    Layout.fillWidth: true
                    columns: canvas.width < 380 ? 1 : 3
                    columnSpacing: Metrics.space6
                    rowSpacing: Metrics.space6

                    ActionButton {
                        objectName: "screenshotCopy"
                        Layout.fillWidth: true
                        text: Strings.screenshotCopy
                        glyph: Icons.copy
                        accent: true
                        enabled: root.interactive
                        onClicked: root.perform("copy")
                        Accessible.name: text
                        ToolTip.visible: hovered
                        ToolTip.text: text + " · Enter / Ctrl+C"
                    }
                    ActionButton {
                        objectName: "screenshotSave"
                        Layout.fillWidth: true
                        text: Strings.screenshotSave
                        glyph: Icons.save
                        enabled: root.interactive
                        onClicked: root.perform("save")
                        Accessible.name: text
                        ToolTip.visible: hovered
                        ToolTip.text: text + " · Ctrl+S"
                    }
                    Item {
                        Layout.fillWidth: true
                        implicitWidth: editButton.implicitWidth
                        implicitHeight: editButton.implicitHeight

                        ActionButton {
                            id: editButton
                            objectName: "screenshotEdit"
                            anchors.fill: parent
                            text: Strings.screenshotEdit
                            glyph: Icons.edit
                            enabled: root.interactive && root.controller.editorAvailable
                            opacity: enabled ? 1 : 0.5
                            onClicked: root.perform("edit")
                            Accessible.name: text
                            Accessible.description: root.controller.editorAvailable ? "" : Strings.screenshotEditorMissing
                        }
                        HoverHandler { id: editHover }
                        ToolTip.visible: editHover.hovered
                        ToolTip.text: root.controller.editorAvailable ? Strings.screenshotEdit + " · E"
                            : Strings.screenshotEditorMissing
                    }
                }

                Text {
                    objectName: "screenshotKeyboardHint"
                    Layout.fillWidth: true
                    visible: !root.selectedHere
                    text: Strings.screenshotKeyboardHint
                    color: Theme.subtext0
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    font.family: Metrics.fontFamily
                    font.pixelSize: Metrics.fontSmall
                }

                Text {
                    objectName: "screenshotError"
                    Layout.fillWidth: true
                    visible: root.controller.errorMessage.length > 0
                    text: root.controller.errorMessage
                    color: Theme.error
                    wrapMode: Text.Wrap
                    font.family: Metrics.fontFamily
                    font.pixelSize: Metrics.fontBody
                    Accessible.name: text
                }
            }
        }
    }
}
