import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.core
import qs.services

Scope {
    WlSessionLock {
        id: sessionLock
        locked: LockService.locked
        onSecureChanged: LockService.setSecure(secure)
        WlSessionLockSurface {
            id: surface
            color: Theme.base
            LockView {
                id: view
                anchors.fill: parent
                auth: LockService
                wallpaperSource: LockService.wallpaperSource
                property bool capturing: false

                function captureExit() {
                    if (!LockService.releasing || capturing || !artworkReady || !entranceFinished) return;
                    capturing = true;
                    const service = LockService;
                    const name = surface.screen.name;
                    const generation = service.generation;
                    // Keep the exact rendered lock (including blur and success
                    // feedback) in memory until its exit animation has finished.
                    if (!grabToImage(result => service.exitCaptured(name, generation, result)))
                        capturing = false;
                }
                onEntranceFinishedChanged: if (entranceFinished) Qt.callLater(captureExit)
                onArtworkReadyChanged: if (artworkReady) Qt.callLater(captureExit)
                Connections {
                    target: LockService
                    function onReleasingChanged() { if (LockService.releasing) view.captureExit(); }
                }
            }
        }
    }
    Variants {
        model: LockService.releasing ? Quickshell.screens.filter(screen => LockService.exitFrames[screen.name]) : []
        LockExit {
            required property var modelData
            shellScreen: modelData
        }
    }
    Connections {
        target: Quickshell
        function onReloadCompleted() { LockService.setSecure(sessionLock.secure); }
    }
}
