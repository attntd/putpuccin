pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Quickshell
import Quickshell.Widgets
import qs.core

FocusScope {
    id: root
    required property var auth
    property url wallpaperSource
    property url avatarSource
    property bool inputEnabled: false
    property bool secretInput: true
    property bool userSelectionEnabled: false
    property bool fingerprintRetryEnabled: false
    signal userSelectionRequested()
    signal fingerprintRetryRequested()
    property bool animateEntrance: true
    readonly property bool artworkReady: width > 0 && height > 0
        && wallpaper.status !== Image.Loading && avatarImage.status !== Image.Loading
    property bool presented: false
    readonly property bool entranceFinished: !entrance.running && content.opacity === 1
    clip: true
    focus: inputEnabled

    function focusPassword() {
        if (visible && password.enabled) password.forceActiveFocus(Qt.OtherFocusReason);
    }
    onVisibleChanged: if (visible) Qt.callLater(focusPassword)
    onActiveFocusChanged: if (activeFocus) focusPassword()
    Window.onActiveChanged: if (Window.active) Qt.callLater(focusPassword)

    function reveal() {
        if (!presented && artworkReady) {
            presented = true;
            if (animateEntrance) entrance.start();
            else content.opacity = 1;
        }
    }
    onArtworkReadyChanged: Qt.callLater(reveal)
    Component.onCompleted: { Qt.callLater(reveal); Qt.callLater(focusPassword); }

    // A lock surface is opaque. Keep the wallpaper in its very first buffer;
    // fading the entire view would expose the window's solid fallback color.
    Rectangle { anchors.fill: parent; color: Theme.base }
    Image {
        id: backdrop
        anchors.fill: parent
        anchors.margins: -Metrics.lockBlurRadius
        source: root.width > 0 && root.height > 0 ? root.wallpaperSource : ""
        sourceSize: Qt.size(Math.ceil(root.width / 2), Math.ceil(root.height / 2))
        fillMode: Image.PreserveAspectCrop
        asynchronous: false
        cache: true
    }
    Item {
        id: content
        objectName: "lockContent"
        anchors.fill: parent
        opacity: 0

        Image {
            id: wallpaper
            anchors.fill: parent
            anchors.margins: -Metrics.lockBlurRadius
            source: backdrop.source
            sourceSize: backdrop.sourceSize
            fillMode: Image.PreserveAspectCrop
            // Both images share Qt's pixmap cache. An asynchronous blur source
            // could make the supposedly synchronous backdrop join its pending
            // decode, exposing a solid first frame.
            asynchronous: false
            cache: true
            layer.enabled: true
            layer.textureSize: Qt.size(Math.ceil(width / 2), Math.ceil(height / 2))
            layer.effect: MultiEffect { blurEnabled: true; blurMax: Metrics.lockBlurRadius; blur: 1.0 }
        }
        Rectangle { anchors.fill: parent; color: Theme.withAlpha(Theme.base, 0.22) }

        ClippingRectangle {
            id: avatar
            objectName: "lockAvatar"
            width: Metrics.lockAvatarSize
            height: width
            radius: width / 2
            color: Theme.withAlpha(Theme.base, Settings.surfaceOpacity)
            anchors.horizontalCenter: parent.horizontalCenter
            y: (root.height - height - Metrics.space24 - passwordFrame.height) / 2
            Image {
                id: avatarImage
                asynchronous: true
                anchors.fill: parent
                source: root.avatarSource
                sourceSize: Qt.size(Metrics.lockAvatarSize * 2, Metrics.lockAvatarSize * 2)
                fillMode: Image.PreserveAspectCrop
            }
            Text {
                anchors.centerIn: parent
                visible: avatarImage.status === Image.Error || !root.avatarSource
                text: Icons.user
                color: Theme.text
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.lockAvatarSize / 2
            }
        }
        MouseArea {
            anchors.fill: avatar
            enabled: root.userSelectionEnabled
            cursorShape: Qt.PointingHandCursor
            onClicked: root.userSelectionRequested()
            Accessible.role: Accessible.Button
            Accessible.name: Strings.greeterSelectUser
        }
        Rectangle {
            id: passwordFrame
            objectName: "lockPasswordFrame"
            anchors.horizontalCenter: parent.horizontalCenter
            y: avatar.y + avatar.height + Metrics.space24
            width: Math.max(0, Math.min(Metrics.lockFieldWidth, root.width - Metrics.space24 * 2))
            height: Metrics.lockFieldHeight
            radius: Metrics.popupRadius
            color: Theme.withAlpha(Theme.base, Settings.surfaceOpacity)
            TextField {
                id: password
                objectName: "lockPassword"
                x: Metrics.space12
                width: parent.width - Metrics.space24
                    - (fingerprint.visible ? fingerprint.width + Metrics.space12 : 0)
                height: parent.height
                leftPadding: 0
                rightPadding: 0
                clip: true
                echoMode: root.secretInput ? TextInput.Password : TextInput.Normal
                passwordCharacter: "●"
                horizontalAlignment: TextInput.AlignHCenter
                color: Theme.text
                selectionColor: Theme.accent
                selectedTextColor: Theme.base
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.lockPasswordDotSize
                font.letterSpacing: Metrics.space2
                enabled: root.inputEnabled && !root.auth.busy
                focus: true
                activeFocusOnPress: true
                inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText | Qt.ImhHiddenText
                Accessible.name: Strings.lockPassword
                // An empty delegate hides the caret even when Qt restores focus.
                cursorDelegate: Item { objectName: "hiddenPasswordCursor" }
                background: null
                onAccepted: root.auth.submit(text)
                Keys.onTabPressed: if (root.userSelectionEnabled) root.userSelectionRequested()
                Keys.onEscapePressed: clear()
                onEnabledChanged: if (enabled) Qt.callLater(root.focusPassword)
                Text {
                    objectName: "lockError"
                    anchors.fill: parent
                    anchors.margins: Metrics.space4
                    visible: password.length === 0 && text.length > 0
                    text: root.auth.message
                    color: Theme.red
                    font.family: Metrics.fontFamily
                    font.pixelSize: Metrics.fontSmall
                    wrapMode: Text.Wrap
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
            Text {
                id: fingerprint
                objectName: "lockFingerprint"
                visible: root.auth.fingerprintAvailable
                anchors.right: parent.right
                anchors.rightMargin: Metrics.space12
                anchors.verticalCenter: parent.verticalCenter
                width: Metrics.lockFingerprintSize
                horizontalAlignment: Text.AlignHCenter
                text: Icons.fingerprint
                color: root.auth.fingerprintState === "success" ? Theme.green
                    : root.auth.fingerprintState === "failure" ? Theme.red : Theme.text
                font.family: Metrics.fontFamily
                font.pixelSize: Metrics.lockFingerprintSize
                Accessible.name: Strings.lockFingerprint
                MouseArea {
                    anchors.fill: parent
                    enabled: root.fingerprintRetryEnabled
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.fingerprintRetryRequested()
                    Accessible.role: Accessible.Button
                    Accessible.name: Strings.greeterRetryFingerprint
                }
                Behavior on color { ColorAnimation { duration: Settings.reducedMotion ? 0 : Motion.fast } }
            }
        }
    }
    NumberAnimation {
        id: entrance
        target: content
        property: "opacity"
        from: 0
        to: 1
        duration: Settings.reducedMotion ? Motion.fast : Motion.lockFade
        easing.type: Easing.InOutSine
    }
    Connections {
        target: root.auth
        function onClearPassword() { password.clear(); }
    }
}
