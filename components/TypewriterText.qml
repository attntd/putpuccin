pragma ComponentBehavior: Bound

import QtQuick
import qs.core

Text {
    id: root

    property string sourceText: ""
    // Only switching windows starts a new animation. Live title updates (CLI
    // spinners, progress, attention states) must not erase the visible text.
    property string contextKey: ""
    property int revealedCharacters: 0
    property bool animating: false
    readonly property string displayedText: typing
        ? sourceText.slice(0, revealedCharacters) : sourceText
    readonly property bool typing: animating && visible && !Settings.reducedMotion

    text: displayedText

    function advance() {
        const target = root.sourceText;
        const step = Math.max(1, Math.ceil(target.length / 45));
        root.revealedCharacters = Math.min(target.length, root.revealedCharacters + step);
        if (root.revealedCharacters >= target.length)
            root.animating = false;
    }

    function restartForContext() {
        root.revealedCharacters = 0;
        root.animating = root.visible && !Settings.reducedMotion && root.sourceText.length > 0;
    }

    // Coalesce the title and window identity bindings in the same event turn.
    onContextKeyChanged: Qt.callLater(root.restartForContext)
    // Hidden text resumes with the current complete value, without replaying
    // an animation the user could not see.
    onVisibleChanged: if (!visible) root.animating = false

    Timer {
        interval: Motion.typewriterStep
        running: root.typing
        repeat: true
        onTriggered: root.advance()
    }

    Connections {
        target: Settings
        function onReducedMotionChanged() {
            if (Settings.reducedMotion)
                root.animating = false;
        }
    }
}
