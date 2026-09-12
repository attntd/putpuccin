pragma ComponentBehavior: Bound

import QtQuick
import qs.core

Item {
    id: root
    property url source
    property real pixelRatio: 1
    readonly property bool transitioning: fade.running
    readonly property string displayedSource: front ? String(front.source) : ""
    property Image front: null
    property Image incoming: null
    signal loadFailed(string source)

    function request() {
        // Coalesce requests during a fade; never discard the visible image
        // until its replacement has decoded successfully.
        if (fade.running) return;
        if (!String(source)) {
            first.source = "";
            second.source = "";
            front = null;
            incoming = null;
            return;
        }
        if (front && String(front.source) === String(source)) {
            if (incoming) incoming.source = "";
            incoming = null;
            return;
        }
        incoming = front === first ? second : first;
        incoming.opacity = 0;
        incoming.z = 1;
        if (front) front.z = 0;
        incoming.source = source;
    }

    function loaded(image) {
        if (image !== incoming) return;
        if (image.status === Image.Error) {
            const failed = String(image.source);
            // Resizing/scaling may reload a buffer during its crossfade.
            // A failed reload must not let onFinished publish a null image.
            fade.stop();
            incoming = null;
            image.opacity = 0;
            image.source = "";
            loadFailed(failed);
        } else if (image.status === Image.Ready && !fade.running) {
            if (!front) finish();
            else fade.start();
        }
    }

    function finish() {
        if (!incoming || incoming.status !== Image.Ready) return;
        const old = front;
        front = incoming;
        incoming = null;
        front.opacity = 1;
        front.z = 0;
        if (old) {
            old.opacity = 0;
            old.source = "";
        }
        Qt.callLater(root.request);
    }

    onSourceChanged: Qt.callLater(root.request)
    Component.onCompleted: Qt.callLater(root.request)

    // Only two decoded images during a transition, one while idle. No shader
    // or image cache retaining every wallpaper visited during the session.
    component Buffer: Image {
        anchors.fill: parent
        asynchronous: true
        cache: false
        autoTransform: true
        retainWhileLoading: true
        fillMode: Image.PreserveAspectCrop
        sourceSize: Qt.size(Math.max(1, Math.round(root.width * root.pixelRatio)),
            Math.max(1, Math.round(root.height * root.pixelRatio)))
        opacity: 0
        onStatusChanged: root.loaded(this)
    }

    Buffer { id: first }
    Buffer { id: second }

    NumberAnimation {
        id: fade
        target: root.incoming
        property: "opacity"
        from: 0
        to: 1
        // A desktop crossfade intentionally lasts longer than control motion.
        duration: Settings.reducedMotion ? Motion.fast : Settings.wallpaperTransitionDuration
        easing.type: Easing.InOutSine
        onFinished: root.finish()
    }
}
