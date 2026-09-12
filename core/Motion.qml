pragma Singleton

import Quickshell

Singleton {
    readonly property int fast: 120
    readonly property int standard: 180
    readonly property int elaborate: 240
    readonly property int lockFade: 400
    readonly property int typewriterStep: 18
    // Reading overflow is functional motion, paced by distance rather than
    // the short surface-transition durations.
    readonly property int textScrollPause: 700
    readonly property int textScrollPixelsPerSecond: 30
    readonly property var emphasized: [0.2, 0.0, 0.0, 1.0]
}
