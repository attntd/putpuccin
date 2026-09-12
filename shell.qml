//@ pragma ShellId quickshell-de
//@ pragma DataDir $BASE/quickshell-de
//@ pragma StateDir $BASE/quickshell-de
//@ pragma CacheDir $BASE/quickshell-de

import Quickshell
import qs.components
import qs.core
import qs.modules.wallpaper
import qs.modules.statusbar
import qs.modules.osd
import qs.modules.workspaces
import qs.modules.notifications
import qs.modules.lockscreen
import qs.modules.screenshot
import qs.modules.authentication
import qs.modules.network
import qs.services

ShellRoot {
    id: root

    // Touch the singletons here so their lifecycle belongs to the shell, not to
    // whichever visual module happens to use them first.
    readonly property var notificationServer: NotificationService
    readonly property var settingsStore: Settings
    readonly property var surfaceCoordinator: SurfaceManager
    readonly property var caffeinate: CaffeinateService
    readonly property var bluetooth: BluetoothService

    readonly property var levelIndicator: OsdService

    Wallpaper {}
    LockScreen {}
    Screenshot {}
    Authentication {}
    NetworkWindow {}

    Variants {
        model: Quickshell.screens
        WorkspaceSwitcher {
            required property var modelData
            shellScreen: modelData
            screenName: modelData.name
        }
    }

    Variants {
        model: Quickshell.screens
        LevelOsd {
            required property var modelData
            screen: modelData
            screenName: modelData.name
        }
    }

    Variants {
        model: Quickshell.screens

        StatusBar {
            required property var modelData
            screen: modelData
        }
    }

    Variants {
        model: Quickshell.screens

        DetachedLauncher {
            required property var modelData
            screen: modelData
        }
    }
    Variants {
        model: Quickshell.screens
        NotificationToasts {
            required property var modelData
            screen: modelData
        }
    }
}
