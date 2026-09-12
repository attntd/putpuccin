pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.core
import qs.services

Scope {
    id: root
    readonly property var controller: ScreenshotService

    LazyLoader {
        active: root.controller.phase === "capturing"
        component: Scope {
            Variants {
                model: Quickshell.screens
                ScreenshotCapture {
                    required property var modelData
                    shellScreen: modelData
                    controller: root.controller
                }
            }
        }
    }
    LazyLoader {
        active: ["selecting", "exporting", "working"].indexOf(root.controller.phase) >= 0
        component: Scope {
            Variants {
                model: Quickshell.screens
                ScreenshotOverlay {
                    required property var modelData
                    shellScreen: modelData
                    controller: root.controller
                }
            }
        }
    }
    Variants {
        model: root.controller.active ? Quickshell.screens : []
        Connections {
            required property var modelData
            target: modelData
            function onGeometryChanged() { root.controller.checkScreens(); }
            function onPhysicalPixelDensityChanged() { root.controller.checkScreens(); }
            function onOrientationChanged() { root.controller.checkScreens(); }
        }
    }
}
