import Quickshell
import Quickshell.Io
import qs.services

ShellRoot {
    property var brightness: BrightnessService
    property var osd: OsdService

    IpcHandler {
        target: "brightnesstest"
        function snapshot(): string {
            return JSON.stringify({state: BrightnessService.state,
                raw: BrightnessService.rawBrightness, maximum: BrightnessService.maximumBrightness,
                percentage: BrightnessService.percentage, target: BrightnessService.targetPercentage,
                slider: BrightnessService.sliderPercentage, pending: BrightnessService.commandPending,
                error: BrightnessService.errorMessage, osd: OsdService.value, osdKind: OsdService.kind});
        }
        function refresh(): void { BrightnessService.refresh(); }
        function rapid(): void {
            BrightnessService.adjust(-5);
            BrightnessService.adjust(-5);
            BrightnessService.adjust(5);
        }
        function invalid(): void {
            BrightnessService.setPercentage(NaN);
            BrightnessService.adjust(Infinity);
            BrightnessService.adjust(-Infinity);
            BrightnessService.adjust(0);
        }
    }
}
