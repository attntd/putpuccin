//@ pragma ShellId power-confirmation-test
import QtQuick
import QtQuick.Window
import QtTest
import Quickshell
import Quickshell.Io
import qs.core
import qs.services
import qs.popups

ShellRoot {
    Window {
        id: window
        visible: true
        width: 420
        height: 520
        color: Theme.base

        Loader {
            id: loader
            x: 20
            y: 20
            width: 360
            sourceComponent: PowerPopup { screenName: "power-test" }
        }

        TestCase {
            id: tests
            when: false

            function check(ok, message) {
                if (!ok) throw new Error(message);
            }
            function controls(item, text, includeHidden) {
                let found = [];
                if (item.text === text && typeof item.clicked === "function" && (includeHidden || item.visible))
                    found.push(item);
                for (const child of item.children || [])
                    found = found.concat(controls(child, text, includeHidden));
                return found;
            }
            function button(text) {
                const found = controls(loader.item, text, false);
                check(found.length === 1, "Expected one visible " + text + ": " + found.length);
                return found[0];
            }
            function click(text) {
                const control = button(text);
                mouseClick(control, control.width / 2, control.height / 2);
            }
            function settle() {
                wait(Settings.reducedMotion ? 25 : 220);
                check(waitForPolish(window, 500), "Layout failed to settle");
            }
            function checkInline(actionLabel, nextLabel) {
                const action = button(actionLabel);
                const cancel = button(Strings.cancel);
                const confirm = button(Strings.confirm);
                const a = action.mapToItem(loader.item, 0, 0);
                const c = cancel.mapToItem(loader.item, 0, 0);
                const f = confirm.mapToItem(loader.item, 0, 0);
                check(Math.abs(c.y - (a.y + action.height + Metrics.space8)) < 0.1,
                      actionLabel + " confirmation is not immediately below its action");
                check(c.x === a.x && c.y === f.y, "Confirmation alignment differs");
                check(Math.abs(cancel.width - confirm.width) < 1 &&
                      Math.abs(f.x + confirm.width - a.x - action.width) < 0.1,
                      "Confirmation buttons do not fill action width evenly");
                if (nextLabel) {
                    const next = button(nextLabel).mapToItem(loader.item, 0, 0);
                    check(next.y >= c.y + cancel.height + Metrics.space8 - 0.1,
                          "Confirmation overlaps the next action");
                }
                check(loader.item.width === 360, "Confirmation changed panel width");
            }
            function fresh(reduced) {
                Settings.reducedMotion = reduced;
                SystemActions.reset();
                SurfaceManager.closeOn("power-test");
                settle();
            }
            function smoke(reduced) {
                fresh(reduced);
                click(Strings.poweroff);
                settle();
                click(Strings.cancel);
                settle();
                loader.active = false;
                wait(20);
                check(loader.item === null, "Closed loader retained its panel");
                loader.active = true;
                settle();
                check(loader.item.confirmation === "", "Recreated panel retained selection");
                return {passed: true};
            }
            function run(reduced) {
                fresh(reduced);
                const actions = [
                    ["logout", Strings.logout, Strings.suspend],
                    ["reboot", Strings.reboot, Strings.poweroff],
                    ["poweroff", Strings.poweroff, ""]
                ];
                const baseHeight = loader.item.implicitHeight;
                for (const entry of actions) {
                    click(entry[1]);
                    settle();
                    check(loader.item.confirmation === entry[0], "Wrong selection");
                    check(SystemActions.executed.length === 0, "Selecting executed an action");
                    checkInline(entry[1], entry[2]);
                    click(Strings.cancel);
                    settle();
                    check(loader.item.confirmation === "", "Cancel did not clear selection");
                    check(button(entry[1]).activeFocus, "Cancel did not restore action focus");
                    check(controls(loader.item, Strings.confirm, false).length === 0, "Cancelled pair remained visible");
                    check(loader.item.implicitHeight === baseHeight, "Cancel retained extra height");
                    click(entry[1]);
                    settle();
                    click(Strings.confirm);
                    check(SystemActions.executed.join() === entry[0], "Confirm executed the wrong action");
                    settle();
                    SystemActions.reset();
                }

                click(Strings.poweroff);
                if (!reduced) {
                    let previousHeight = baseHeight;
                    let intermediateFrames = 0;
                    for (let frame = 0; frame < 14; frame++) {
                        wait(16);
                        check(waitForPolish(window, 500), "Animation layout failed to settle");
                        const currentHeight = loader.item.implicitHeight;
                        check(currentHeight >= previousHeight - 0.1 && currentHeight <= baseHeight + 46.1,
                              "Expansion height jumped or reversed");
                        check(loader.item.width === 360, "Animation changed panel width");
                        if (currentHeight > baseHeight && currentHeight < baseHeight + 46)
                            intermediateFrames++;
                        previousHeight = currentHeight;
                    }
                    check(intermediateFrames > 0, "Expansion skipped its animation");
                }
                settle();
                const oldConfirm = button(Strings.confirm);
                click(Strings.reboot);
                check(!oldConfirm.enabled, "Previous action stayed interactive during transition");
                oldConfirm.clicked();
                check(SystemActions.executed.length === 0, "Stale callback executed old action");
                settle();
                checkInline(Strings.reboot, Strings.poweroff);
                click(Strings.confirm);
                check(SystemActions.executed.join() === "reboot", "Confirm did not execute only selected action");
                check(loader.item.confirmation === "", "Confirm retained selection");
                settle();

                SystemActions.reset();
                click(Strings.logout);
                settle();
                SystemActions.busy = true;
                check(!button(Strings.cancel).enabled && !button(Strings.confirm).enabled, "Busy controls stayed enabled");
                button(Strings.confirm).clicked();
                check(SystemActions.executed.length === 0, "Busy confirm executed");
                SystemActions.busy = false;
                SystemActions.unavailableAction = "logout";
                check(!button(Strings.confirm).enabled, "Unavailable confirm stayed enabled");
                button(Strings.confirm).clicked();
                check(SystemActions.executed.length === 0, "Unavailable confirm executed");
                SystemActions.reset();
                SurfaceManager.changed("other-monitor", "");
                check(loader.item.confirmation === "logout", "Other monitor cleared selection");
                SurfaceManager.changed("power-test", "calendar");
                check(loader.item.confirmation === "", "Switching panel retained selection");
                settle();

                // Native Button keyboard activation and focus order.
                window.requestActivate();
                button(Strings.poweroff).forceActiveFocus(Qt.TabFocusReason);
                keyClick(Qt.Key_Space);
                settle();
                keyClick(Qt.Key_Tab);
                check(button(Strings.cancel).activeFocus, "Tab did not reach Cancel first");
                keyClick(Qt.Key_Tab);
                check(button(Strings.confirm).activeFocus, "Tab did not reach Confirm second");
                keyClick(Qt.Key_Space);
                check(SystemActions.executed.join() === "poweroff", "Keyboard confirmation failed");
                settle();

                // Vim navigation preserves the confirmation step.
                SystemActions.reset();
                loader.item.focusDefaultControl();
                check(button(Strings.lock).activeFocus, "Opening did not select the first action");
                keyClick(Qt.Key_J);
                check(button(Strings.logout).activeFocus, "J did not select Logout");
                keyClick(Qt.Key_Return); settle();
                check(loader.item.confirmation === "logout" && !SystemActions.executed.length,
                    "Enter skipped the confirmation step");
                keyClick(Qt.Key_J);
                check(button(Strings.cancel).activeFocus, "J did not select Cancel");
                keyClick(Qt.Key_L);
                check(button(Strings.confirm).activeFocus, "L did not select Confirm");
                keyClick(Qt.Key_H);
                check(button(Strings.cancel).activeFocus, "H did not return to Cancel");
                keyClick(Qt.Key_Escape); settle();
                check(!loader.item.confirmation && button(Strings.logout).activeFocus,
                    "Escape did not cancel and restore focus");
                SystemActions.unavailableAction = "suspend";
                keyClick(Qt.Key_J);
                check(button(Strings.hibernate).activeFocus, "J did not skip the unavailable action");
                keyClick(Qt.Key_K);
                check(button(Strings.logout).activeFocus, "K did not skip the unavailable action");
                keyClick(Qt.Key_Return); settle();
                keyClick(Qt.Key_J); keyClick(Qt.Key_L); keyClick(Qt.Key_Return); settle();
                check(SystemActions.executed.join() === "logout", "Vim confirmation did not execute once");

                // Unconfirmed actions keep their existing execution policy.
                for (const entry of [["lock", Strings.lock], ["suspend", Strings.suspend], ["hibernate", Strings.hibernate]]) {
                    SystemActions.reset();
                    click(Strings.reboot);
                    settle();
                    click(entry[1]);
                    check(SystemActions.executed.join() === entry[0] && loader.item.confirmation === "",
                          "Immediate action retained stale confirmation or changed policy");
                    settle();
                }
                SystemActions.reset();
                click(Strings.logout);
                settle();
                SystemActions.succeeded("logout");
                check(loader.item.confirmation === "", "Success did not clear closed selection");
                settle();
                click(Strings.poweroff);
                settle();
                SurfaceManager.changed("", "");
                check(loader.item.confirmation === "", "Global close retained selection");
                settle();
                check(loader.item.implicitHeight === baseHeight, "Final layout differs from baseline");
                return smoke(reduced);
            }
            function screenshots() {
                fresh(true);
                for (const entry of [["logout", Strings.logout], ["reboot", Strings.reboot], ["poweroff", Strings.poweroff]]) {
                    click(entry[1]);
                    settle();
                    const path = Quickshell.env("QS_POWER_PROOF") + "/" + entry[0] + ".png";
                    loader.item.grabToImage(result => result.saveToFile(path));
                    wait(80);
                }
                SurfaceManager.closeOn("power-test");
                return true;
            }
        }
    }
    IpcHandler {
        target: "powertest"
        function ready(): bool { return !!loader.item; }
        function run(reduced: bool): string {
            try { return JSON.stringify(tests.run(reduced)); }
            catch (error) { return JSON.stringify({passed: false, error: String(error)}); }
        }
        function smoke(reduced: bool): string {
            try { return JSON.stringify(tests.smoke(reduced)); }
            catch (error) { return JSON.stringify({passed: false, error: String(error)}); }
        }
        function screenshots(): bool { return tests.screenshots(); }
    }
}
