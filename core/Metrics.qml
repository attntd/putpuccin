pragma Singleton

import Quickshell

Singleton {
    readonly property int authWidth: 440
    readonly property int space2: 2
    readonly property int space4: 4
    readonly property int space6: 6
    readonly property int space8: 8
    readonly property int space12: 12
    readonly property int space16: 16
    readonly property int space20: 20
    readonly property int space24: 24

    readonly property int barHeight: 40
    readonly property int barTopMargin: 8
    readonly property int barSideMargin: 12
    readonly property int barGap: 8
    readonly property int barReservedHeight: 48
    readonly property int barRadius: 14
    readonly property int controlHeight: 32
    readonly property int mediaArtworkSize: 104
    readonly property int mediaTransportButtonWidth: 42
    readonly property int mediaTransportPrimaryWidth: 48
    readonly property int mediaTransportWidth: 2 * mediaTransportButtonWidth
        + mediaTransportPrimaryWidth + 4 * space6
    readonly property int mediaPanelMaximumWidth: 560
    readonly property int popupRowHeight: 44
    readonly property int launcherRowHeight: 48
    readonly property int launcherVisibleRows: 5
    readonly property int launcherScreenMargin: 25
    readonly property int launcherChipRadius: 8
    readonly property int minHitSize: 32
    readonly property int popupWidth: 410
    readonly property int networkSettingsHeight: 620
    readonly property int networkWindowWidth: 900
    readonly property int networkWindowHeight: 680
    readonly property int networkWindowMinimumWidth: 600
    readonly property int networkWindowMinimumHeight: 460
    readonly property int networkSidebarWidth: 176
    readonly property int bluetoothPickerListHeight: 420
    readonly property int lockAvatarSize: 150
    readonly property int lockFieldWidth: 320
    readonly property int lockPasswordDotSize: 22
    readonly property int lockFieldHeight: 48
    readonly property int lockFingerprintSize: 30
    readonly property int lockBlurRadius: 32
    readonly property int workspaceTileWidth: 300
    readonly property int workspaceTileHeight: 200
    readonly property int screenshotToolbarMaximumWidth: 720
    readonly property int screenshotSelectionBorderWidth: 2
    readonly property int screenshotSelectionHandleSize: 6
    readonly property int popupRadius: 16
    readonly property int popupPadding: 16
    readonly property int borderWidth: 1

    readonly property int iconSmall: 14
    readonly property int iconMedium: 18
    readonly property int iconLarge: 24
    readonly property int fontSmall: 11
    readonly property int fontBody: 13
    readonly property int fontTitle: 15
    readonly property string fontFamily: "JetBrainsMono Nerd Font"
}
