pragma Singleton

import QtQuick
import Quickshell

Singleton {
    // Catppuccin Mocha. Visual modules must consume these semantic aliases,
    // never embed palette literals of their own.
    readonly property color rosewater: "#f5e0dc"
    readonly property color flamingo: "#f2cdcd"
    readonly property color pink: "#f5c2e7"
    readonly property color mauve: "#cba6f7"
    readonly property color red: "#f38ba8"
    readonly property color maroon: "#eba0ac"
    readonly property color peach: "#fab387"
    readonly property color yellow: "#f9e2af"
    readonly property color green: "#a6e3a1"
    readonly property color teal: "#94e2d5"
    readonly property color sky: "#89dceb"
    readonly property color sapphire: "#74c7ec"
    readonly property color blue: "#89b4fa"
    readonly property color lavender: "#b4befe"
    readonly property color text: "#cdd6f4"
    readonly property color subtext1: "#bac2de"
    readonly property color subtext0: "#a6adc8"
    readonly property color overlay2: "#9399b2"
    readonly property color overlay1: "#7f849c"
    readonly property color overlay0: "#6c7086"
    readonly property color surface2: "#585b70"
    readonly property color surface1: "#45475a"
    readonly property color surface0: "#313244"
    readonly property color base: "#1e1e2e"
    readonly property color mantle: "#181825"
    readonly property color crust: "#11111b"

    readonly property color accent: mauve
    readonly property color success: green
    readonly property color warning: yellow
    readonly property color error: red
    readonly property color info: blue
    readonly property color launcherBackdrop: withAlpha(base, 0.55)
    readonly property color authenticationBackdrop: launcherBackdrop

    function withAlpha(value, alpha) {
        return Qt.rgba(value.r, value.g, value.b, alpha);
    }

    // The panel supplies the glass. Do not stack another opaque surface on it.
    function controlBackground(value, hovered = false, pressed = false, selected = false) {
        const stateAlpha = pressed ? 0.14 : selected ? 0.12 : hovered ? 0.08 : 0;
        return withAlpha(value, Math.min(1, Settings.interactiveOpacity + stateAlpha));
    }
}
