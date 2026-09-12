//@ pragma Env QML_IMPORT_PATH = /home/attntd/.config/quickshell/integrations
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.core
import qs.services
import qs.modules.authentication

ShellRoot {
    id: root
    Variants {
        model: Quickshell.screens
        PanelWindow {
            required property var modelData
            screen: modelData
            anchors { top: true; right: true; bottom: true; left: true }
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: WlrLayer.Bottom
            WlrLayershell.namespace: "auth-review-background"
            mask: Region {}
            color: Theme.surface2
            Repeater {
                model: 80
                Rectangle {
                    required property int index
                    x: index * 20
                    width: 10
                    height: 1000
                    color: index % 2 ? Theme.lavender : Theme.blue
                }
            }
        }
    }
    Authentication { id: authentication }
    IpcHandler {
        target: "review"
        function state(): string {
            const auth = AuthenticationService;
            return JSON.stringify({active: auth.active, interactive: auth.interactive,
                input: auth.needsInput, count: auth.pendingCount, error: auth.error,
                polkit: auth.flow !== null, retained: authentication.retained,
                prompt: auth.prompt, supplementary: auth.supplementary,
                screen: authentication.targetScreen ? authentication.targetScreen.name : "",
                registered: auth.registered});
        }
        function reload(): void { Quickshell.reload(false); }
        function reduced(value: bool): void { Settings.reducedMotion = value; }
        function denyAll(): void { AuthenticationService.cancelAll(); }
        function polkit(): void { AuthenticationService.reviewPolkit(); }
        function supplementary(value: string): void { AuthenticationService.flow.supplementaryMessage = value; }
        function capture(value: bool): void { AuthenticationService.reviewCapture = value; }
    }
}
