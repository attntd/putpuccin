import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.core
import qs.components

Rectangle {
    id: root
    objectName: "authenticationView"
    required property var auth
    // Retain non-secret presentation during exit; the live request may already
    // have disappeared, while its final frame is still fading out.
    property var presentation: ({
            title: "",
            message: "",
            detail: "",
            prompt: "",
            supplementary: "",
            error: false,
            interactive: false,
            needsInput: false,
            identities: [],
            polkit: false
        })
    readonly property var livePresentation: ({
            title: auth.title,
            message: auth.message,
            detail: auth.detail,
            prompt: auth.prompt,
            supplementary: auth.supplementary,
            error: auth.error,
            interactive: auth.interactive,
            needsInput: auth.needsInput,
            identities: auth.identities,
            polkit: auth.flow !== null
        })
    onLivePresentationChanged: if (auth.active)
        presentation = livePresentation
    implicitHeight: content.implicitHeight + Metrics.popupPadding * 2
    radius: Metrics.popupRadius
    color: Theme.withAlpha(Theme.base, Settings.surfaceOpacity)
    border.width: 0
    focus: true

    function focusInput() {
        response.clear();
        if (auth.needsInput) {
            response.forceActiveFocus();
            Qt.callLater(scrollToInput);
        } else if (auth.interactive)
            cancel.forceActiveFocus();
    }
    function scrollToInput() {
        if (!auth.needsInput)
            return;
        const bottom = response.mapToItem(content, 0, response.height).y + Metrics.popupPadding;
        scroll.contentY = Math.max(0, Math.min(scroll.contentHeight - scroll.height, bottom - scroll.height + Metrics.popupPadding));
    }
    function prepareLayout() {
        content.ensurePolished();
        scrollToInput();
    }
    function accept() {
        const value = response.text;
        response.clear();
        auth.submit(value);
    }
    Component.onCompleted: {
        presentation = livePresentation;
        Qt.callLater(focusInput);
    }
    Connections {
        target: root.auth
        function onClearInput() {
            root.focusInput();
        }
    }
    Keys.onEscapePressed: event => {
        if (auth.interactive)
            auth.cancel();
        event.accepted = true;
    }

    Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight + Metrics.popupPadding * 2
        boundsBehavior: Flickable.StopAtBounds
        clip: true
        ScrollBar.vertical: ScrollBar {
            // A fitted surface can differ by a subpixel at fractional scale.
            policy: scroll.contentHeight - scroll.height > 1 ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
            background: null
            contentItem: Rectangle {
                implicitWidth: Metrics.space4
                radius: Metrics.space2
                color: Theme.withAlpha(Theme.text, 0.3)
            }
        }
        ColumnLayout {
            id: content
            anchors {
                left: parent.left
                right: parent.right
                top: parent.top
                margins: Metrics.popupPadding
            }
            spacing: Metrics.space12
            RowLayout {
                spacing: Metrics.space12
                Text {
                    text: root.presentation.polkit ? Icons.lock : Icons.authKey
                    color: Theme.accent
                    font.family: Metrics.fontFamily
                    font.pixelSize: Metrics.iconLarge
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Metrics.space4
                    Text {
                        Layout.fillWidth: true
                        text: root.presentation.title
                        textFormat: Text.PlainText
                        color: Theme.text
                        font {
                            family: Metrics.fontFamily
                            pixelSize: Metrics.fontTitle
                            weight: Font.DemiBold
                        }
                        wrapMode: Text.Wrap
                    }
                    Text {
                        Layout.fillWidth: true
                        visible: !root.presentation.interactive
                        text: Strings.authTouchHint
                        color: Theme.subtext1
                        font {
                            family: Metrics.fontFamily
                            pixelSize: Metrics.fontBody
                        }
                        wrapMode: Text.Wrap
                    }
                }
            }
            Text {
                Layout.fillWidth: true
                text: root.presentation.message
                visible: text.length > 0
                textFormat: Text.PlainText
                color: Theme.subtext1
                font {
                    family: Metrics.fontFamily
                    pixelSize: Metrics.fontBody
                }
                wrapMode: Text.Wrap
            }
            Text {
                Layout.fillWidth: true
                text: root.presentation.detail
                visible: text.length > 0
                textFormat: Text.PlainText
                color: Theme.subtext0
                font {
                    family: Metrics.fontFamily
                    pixelSize: Metrics.fontSmall
                }
                wrapMode: Text.Wrap
            }
            Flow {
                Layout.fillWidth: true
                visible: root.presentation.identities.length > 1
                spacing: Metrics.space6
                Repeater {
                    model: root.auth.active ? root.auth.identities : []
                    ActionButton {
                        required property var modelData
                        required property int index
                        borderless: true
                        text: modelData.displayName
                        accent: root.auth.flow && root.auth.flow.selectedIdentity === modelData
                        onClicked: root.auth.selectIdentity(index)
                    }
                }
            }
            Text {
                Layout.fillWidth: true
                visible: root.presentation.supplementary.length > 0
                text: root.presentation.supplementary
                textFormat: Text.PlainText
                color: root.presentation.error ? Theme.error : Theme.subtext1
                font {
                    family: Metrics.fontFamily
                    pixelSize: Metrics.fontBody
                }
                wrapMode: Text.Wrap
            }
            Text {
                Layout.fillWidth: true
                visible: root.presentation.needsInput
                text: root.presentation.prompt || Strings.authSecret
                textFormat: Text.PlainText
                color: Theme.text
                font {
                    family: Metrics.fontFamily
                    pixelSize: Metrics.fontBody
                }
                wrapMode: Text.Wrap
            }
            TextField {
                id: response
                objectName: "authenticationResponse"
                Layout.fillWidth: true
                visible: root.presentation.needsInput
                enabled: root.auth.needsInput
                implicitHeight: Metrics.popupRowHeight
                color: Theme.text
                selectionColor: Theme.accent
                selectedTextColor: Theme.base
                echoMode: root.auth.responseVisible ? TextInput.Normal : TextInput.Password
                passwordCharacter: "●"
                passwordMaskDelay: 0
                inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText | Qt.ImhNoAutoUppercase
                maximumLength: 1024
                font {
                    family: Metrics.fontFamily
                    pixelSize: Metrics.fontBody
                }
                leftPadding: Metrics.space12
                rightPadding: Metrics.space12
                background: Rectangle {
                    radius: Metrics.space8
                    color: Theme.controlBackground(Theme.text, response.hovered)
                    border.width: Metrics.borderWidth
                    border.color: Theme.surface1
                }
                onAccepted: root.accept()
            }
            RowLayout {
                Layout.fillWidth: true
                visible: root.presentation.interactive
                Item {
                    Layout.fillWidth: true
                }
                ActionButton {
                    id: cancel
                    borderless: true
                    text: Strings.cancel
                    onClicked: root.auth.cancel()
                    Keys.onReturnPressed: root.auth.cancel()
                    Keys.onEnterPressed: root.auth.cancel()
                }
                ActionButton {
                    borderless: true
                    text: Strings.confirm
                    accent: true
                    enabled: root.auth.needsInput || !root.auth.flow
                    onClicked: root.accept()
                    Keys.onReturnPressed: if (enabled)
                        root.accept()
                    Keys.onEnterPressed: if (enabled)
                        root.accept()
                }
            }
        }
    }
}
