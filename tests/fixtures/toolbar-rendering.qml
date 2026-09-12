import QtQuick
import QtQuick.Window
import QtTest
import Quickshell
import Quickshell.Io
import qs.core
import qs.modules.statusbar

ShellRoot {
    Window {
        id: window
        visible: true
        width: 4096
        height: 128
        color: "black"
        flags: Qt.Tool | Qt.WindowDoesNotAcceptFocus

        BarIsland {
            id: island
            x: window.width - width - Settings.sideMargin
            y: Settings.topMargin
            moduleIds: ["clock"]
            barWindow: window
            shellScreen: ({name: "render-test"})
            contentAlignment: Qt.AlignRight
            animateWidth: false
        }

        BarIsland {
            id: centerIsland
            anchors.horizontalCenter: parent.horizontalCenter
            y: 80
            moduleIds: ["launcher", "context", "media"]
            compactModuleId: "context"
            barWindow: window
            shellScreen: ({name: "render-test"})
            contentAlignment: Qt.AlignHCenter
            animateWidth: false
            animateExpansionWidth: true
        }

        Component {
            id: testsComponent
            TestCase {
                when: false

                function centerFrames(directory) {
                    centerIsland.expansionWidth = 560;
                    const steps = [0, 0.013, 0.079, 0.153, 0.217, 0.319,
                        0.489, 0.611, 0.789, 0.933, 1];
                    const progress = steps.concat(steps.slice(0, -1).reverse());
                    const context = centerIsland.hostForSurface("window");
                    let reference;
                    let referencePosition;
                    const frames = [];
                    for (let index = 0; index < progress.length; index++) {
                        centerIsland.moduleRevealProgress = progress[index];
                        centerIsland.expansionProgress = progress[index];
                        centerIsland.implicitHeight = Settings.barHeight + 230 * progress[index];
                        wait(32);
                        const position = context.mapToItem(window.contentItem, 0, 0);
                        const frame = grabImage(window.contentItem);
                        if (directory)
                            frame.save(directory + "/center-" + index + ".png");
                        if (!reference) {
                            reference = frame;
                            referencePosition = position;
                        }
                        const ratio = frame.width / window.width;
                        let changedPixels = 0;
                        let foregroundPixels = 0;
                        // Compare the whole title and icon, excluding the island corners.
                        for (let y = Math.ceil((referencePosition.y + 3) * ratio);
                                y < Math.floor((referencePosition.y + context.height - 3) * ratio); y++) {
                            for (let x = Math.ceil((referencePosition.x + 8) * ratio);
                                    x < Math.floor((referencePosition.x + context.width - 8) * ratio); x++) {
                                if (reference.red(x, y) > 100)
                                    foregroundPixels++;
                                if (frame.red(x, y) !== reference.red(x, y)
                                        || frame.green(x, y) !== reference.green(x, y)
                                        || frame.blue(x, y) !== reference.blue(x, y))
                                    changedPixels++;
                            }
                        }
                        frames.push({progress: progress[index], x: position.x, y: position.y,
                            width: context.width, islandWidth: centerIsland.width,
                            changedPixels, foregroundPixels});
                        if (frame !== reference)
                            frame.destroy();
                    }
                    reference.destroy();
                    return {passed: frames.every(frame => frame.changedPixels === 0
                        && frame.foregroundPixels > 50 && Math.abs(frame.x - referencePosition.x) < 0.001
                        && frame.y === referencePosition.y), frames};
                }

                function run(directory) {
                    Settings.reducedMotion = true;
                    // Freeze only the displayed time, including across a minute boundary.
                    Settings.clockDateFormat = "'7 wrz'";
                    Settings.clockFormat = "'12:34'";
                    wait(250);
                    const sizes = [[410, 40], [410, 40.3], [410, 87.7],
                        [410, 123.4], [410, 320], [400.3, 320.3], [390.7, 250.7],
                        [380.1, 123.4], [410, 87.7], [410, 40.3], [410, 40]];
                    let reference;
                    const frames = [];
                    for (let index = 0; index < sizes.length; index++) {
                        // Deterministic intermediate animation dimensions: endpoints
                        // alone missed this defect. Keep production layout and layer.
                        island.implicitWidth = sizes[index][0];
                        island.implicitHeight = sizes[index][1];
                        wait(32);
                        const frame = grabImage(window.contentItem);
                        if (directory)
                            frame.save(directory + "/frame-" + index + ".png");
                        if (!reference)
                            reference = frame;
                        let changedPixels = 0;
                        let foregroundPixels = 0;
                        // A native tiling compositor can resize the test window;
                        // captures also use physical pixels on high-DPI screens.
                        const ratio = frame.width / window.width;
                        const left = Math.round((window.width - 190) * ratio);
                        const right = Math.round((window.width - 25) * ratio);
                        // Header interior, excluding corners whose shape must change
                        // as the background expands below the stationary controls.
                        for (let y = Math.round(15 * ratio); y < Math.round(40 * ratio); y++) {
                            for (let x = left; x < right; x++) {
                                if (reference.red(x, y) > 100)
                                    foregroundPixels++;
                                if (frame.red(x, y) !== reference.red(x, y)
                                    || frame.green(x, y) !== reference.green(x, y)
                                    || frame.blue(x, y) !== reference.blue(x, y))
                                    changedPixels++;
                            }
                        }
                        frames.push({width: island.width, height: island.height,
                            right: island.x + island.width, top: island.y,
                            changedPixels, foregroundPixels});
                        if (frame !== reference)
                            frame.destroy();
                    }
                    reference.destroy();
                    const center = centerFrames(directory);
                    return {passed: center.passed && frames.every(frame => frame.changedPixels === 0
                            && frame.foregroundPixels > 50
                            && frame.right === window.width - Settings.sideMargin
                            && frame.top === Settings.topMargin),
                        pixelRatio: window.devicePixelRatio, frames, center};
                }
            }
        }
    }

    IpcHandler {
        target: "toolbarrendertest"
        function ready(): bool { return !!island.hostForSurface("calendar") && !!centerIsland.hostForSurface("window"); }
        function collect(): void { gc(); }
        function run(directory: string): string {
            // Release the per-run QtTest helper after collecting its result.
            const tests = testsComponent.createObject(window.contentItem);
            try {
                return JSON.stringify(tests.run(directory));
            } finally {
                tests.destroy();
            }
        }
    }
}
