//@ pragma ShellId media-integration-test
import QtQuick
import QtQuick.Window
import QtTest
import Quickshell
import Quickshell.Io
import qs.core
import qs.services
import qs.popups
import qs.modules.statusbar

ShellRoot {
    Window {
        id: window
        visible: true
        width: 460
        height: 340
        color: Theme.base
        MediaModule { id: module; x: 16; y: 12; width: implicitWidth; height: implicitHeight; shellScreen: ({name: "media-test"}) }
        Loader {
            id: panel
            x: 10; y: 56; width: 430
            active: true
            sourceComponent: MediaPopup { screenName: "media-test"; embedded: true }
        }
        TestCase { id: tests; when: false }
    }
    IpcHandler {
        target: "mediatest"
        function snapshot(): string {
            tests.wait(20);
            const player = MediaService.activePlayer;
            const selector = panel.item ? tests.findChild(panel.item, "mediaPlayerSelector") : null;
            const timer = panel.item ? tests.findChild(panel.item, "mediaPositionTimer") : null;
            const progress = panel.item ? tests.findChild(panel.item, "mediaProgress") : null;
            return JSON.stringify({count: MediaService.players.length, rawCount: MediaService.rawPlayers.length,
                active: player ? player.identity : null,
                selected: MediaService.selectedPlayer ? MediaService.selectedPlayer.identity : null,
                playing: MediaService.playing, title: MediaService.title, artist: MediaService.artist,
                sourceName: MediaService.sourceName, sourcePageTitle: MediaService.sourcePageTitle,
                album: MediaService.album, hasTimeline: MediaService.hasTimeline,
                timelineDuration: MediaService.timelineDuration,
                timelineDurationPending: MediaService.timelineDurationPending,
                nativeDurationValid: MediaService.nativeDurationValid,
                canSeekTimeline: MediaService.canSeekTimeline,
                positionSupported: player ? player.positionSupported : false,
                nativePosition: player && player.positionSupported ? player.position : null,
                foreground: String(module.children[0].foreground), white: String(Theme.text), mauve: String(Theme.mauve),
                glyph: module.children[0].icon, panelLoaded: !!panel.item,
                timer: timer ? timer.running : null, ticks: panel.item ? panel.item.clockTick : null,
                selectorIndex: selector ? selector.currentIndex : null,
                selectorText: selector ? selector.displayText : null,
                playerLabels: MediaService.players.map(player => MediaService.playerLabel(player)),
                progress: progress ? progress.value : null,
                progressVisible: progress ? progress.visible : null,
                progressEnabled: progress ? progress.enabled : null,
                formattedHour: panel.item ? panel.item.duration(3661) : null,
                artworkFallback: panel.item ? tests.findChild(panel.item, "mediaArtworkFallback").visible : null,
                width: panel.item ? panel.item.width : null,
                height: panel.item ? panel.item.implicitHeight : null,
                canPrevious: panel.item ? tests.findChild(panel.item, "mediaPrevious").enabled : null,
                canNext: panel.item ? tests.findChild(panel.item, "mediaNext").enabled : null,
                canPlayPause: panel.item ? tests.findChild(panel.item, "mediaPlayPause").enabled : null});
        }
        function select(identity: string): void {
            const selector = tests.findChild(panel.item, "mediaPlayerSelector");
            const targetIndex = identity === "" ? 0
                : MediaService.players.findIndex(p => p.identity === identity) + 1;
            tests.mouseClick(selector);
            tests.keyClick(Qt.Key_Home);
            for (let i = 0; i < targetIndex; i++)
                tests.keyClick(Qt.Key_Down);
            tests.keyClick(Qt.Key_Return);
            tests.wait(30);
        }
        function selectLabel(label: string): void {
            const selector = tests.findChild(panel.item, "mediaPlayerSelector");
            const index = MediaService.players.findIndex(p => MediaService.playerLabel(p) === label) + 1;
            tests.mouseClick(selector);
            tests.keyClick(Qt.Key_Home);
            for (let i = 0; i < index; i++) tests.keyClick(Qt.Key_Down);
            tests.keyClick(Qt.Key_Return);
            tests.wait(30);
        }
        function selectorDetails(): string {
            const selector = tests.findChild(panel.item, "mediaPlayerSelector");
            selector.forceActiveFocus();
            const tip = tests.findChild(selector, "mediaSelectorTooltip");
            tests.mouseClick(selector);
            tests.wait(30);
            const option = selector.popup.contentItem.itemAtIndex(selector.currentIndex);
            const optionTip = tests.findChild(option, "mediaOptionTooltip");
            option.forceActiveFocus();
            tests.wait(800);
            const result = JSON.stringify({text: selector.displayText,
                textFormat: selector.contentItem.textFormat, tooltip: tip.contentItem.text,
                tooltipFormat: tip.contentItem.textFormat, option: option.text,
                optionFormat: option.contentItem.textFormat, optionTooltip: optionTip.contentItem.text,
                optionTooltipFormat: optionTip.contentItem.textFormat,
                optionTooltipVisible: optionTip.visible});
            selector.popup.close();
            return result;
        }
        function click(name: string): void {
            tests.mouseClick(tests.findChild(panel.item, name));
            tests.wait(30);
        }
        function keyboardToggle(): void {
            tests.findChild(panel.item, "mediaPlayPause").forceActiveFocus();
            tests.keyClick(Qt.Key_Space);
            tests.wait(30);
        }
        function seek(): void {
            const slider = tests.findChild(panel.item, "mediaProgress");
            tests.mouseClick(slider, slider.width * 0.5, slider.height / 2);
            tests.wait(30);
        }
        function seekValue(seconds: real): void { MediaService.seekTimeline(seconds); tests.wait(30); }
        function shown(show: bool): void { panel.visible = show; }
        function loaded(load: bool): void { panel.active = load; tests.wait(30); }
        function screenshot(path: string): void {
            window.contentItem.grabToImage(result => result.saveToFile(path));
            tests.wait(100);
        }
    }
}
