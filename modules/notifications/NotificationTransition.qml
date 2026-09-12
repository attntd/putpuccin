import QtQuick
import qs.core

QtObject {
    id: root
    property var uids: []
    property var startingValues: ({})
    property string targetUid: ""
    property real progress: 1

    function value(uid) {
        const start = startingValues[uid] || 0;
        return start * (1 - progress) + (uid === targetUid ? progress : 0);
    }

    function select(uid) {
        if (uid === targetUid) return;
        const snapshot = {};
        for (const key of uids) snapshot[key] = value(key);
        animation.stop();
        startingValues = snapshot;
        targetUid = uid;
        progress = 0;
        animation.start();
    }

    function reset() {
        animation.stop();
        startingValues = {};
        targetUid = "";
        progress = 1;
    }

    property NumberAnimation animation: NumberAnimation {
        target: root
        property: "progress"
        to: 1
        duration: Settings.reducedMotion ? Motion.fast : Motion.standard
        easing.type: Easing.InOutCubic
    }
}
