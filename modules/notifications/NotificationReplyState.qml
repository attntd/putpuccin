import QtQml

// Owned by a surface, so a model update can recreate a card without losing
// its draft. This state never crosses a closed surface or a QML reload.
QtObject {
    property string uid: ""
    property string text: ""
    property string error: ""

    function begin(notificationUid) {
        if (uid === notificationUid)
            return;
        reset();
        uid = notificationUid;
    }
    function reset() {
        text = "";
        error = "";
        uid = "";
    }
}
