//@ pragma ShellId notification-card-test
import QtQuick
import QtQuick.Window
import QtTest
import Quickshell
import Quickshell.Io
import qs.core
import qs.services
import qs.modules.notifications
ShellRoot {
    IpcHandler {
        target: "cardtest"
        function run(): string {
            const results = [];
            for (const name of ["test_wholeCard", "test_longCard", "test_buttonsDoNotActivateCard", "test_keyboard", "test_longTitle", "test_secondaryAction", "test_clickControls", "test_keyboardControls", "test_toastControls", "test_toastLongCard", "test_clearConfirmation", "test_toastGeometry", "test_longTextAnimation"]) {
                try { tests.init(); tests[name](); results.push({name:name, passed:true}); }
                catch (e) { results.push({name:name, passed:false, error:String(e)}); }
            }
            return JSON.stringify(results);
        }
    }
    Window {
        id: window
        visible: true
        width: 420
        height: 900
        Item { id: focusSink; x: 410; y: 880; width: 10; height: 10 }
        NotificationCard {
            id: card
            width: 400
            notification: ({uid:"fixture", appName:"Test",summary:"Krótki tytuł",body:"Krótka treść",time:Date.now(),urgency:1,actions:[]})
        }
        Loader {
            id: centerLoader
            active: false
            width: 400
            sourceComponent: NotificationCenter { screenName: "test"; height: implicitHeight }
        }
        SignalSpy { id: actions; target: card; signalName: "activated" }
        TestCase {
            id: tests
            name: "NotificationCard"
            when: false
            function verify(value, message) { if (!value) throw new Error(message || "Verification failed"); }
            function compare(actual, expected) { if (actual !== expected) throw new Error("Expected " + expected + ", received " + actual); }
            function tryCompare(object, key, expected) { wait(80); compare(object[key],expected); }
            function init() {
                Settings.reducedMotion = false;
                centerLoader.active = false;
                card.visible = true;
                card.managedReveal = false;
                card.revealSelected = false;
                card.toast = false;
                card.expanded = false;
                card.controlsOpen = false;
                card.notification = {uid:"fixture", appName:"Test",summary:"Krótki tytuł",body:"Krótka treść",time:Date.now(),urgency:1,actions:[]};
                actions.clear();
                focusSink.forceActiveFocus(Qt.OtherFocusReason);
                mouseMove(window.contentItem, window.width - 1, window.height - 1);
                wait(220);
            }
            function test_wholeCard() {
                verify(!card.expandable);
                mouseClick(card, 2, 2); wait(220);
                compare(actions.count, 0);
                for (const point of [[2,2],[398,2],[2,card.height-2],[200,card.height-2],[10,card.height/2],[100,25],[100,card.height-25]]) {
                    mouseClick(card, point[0], point[1]);
                }
                compare(actions.count,7);
            }
            function test_longCard() {
                card.notification = Object.assign({},card.notification,{body:Array(40).fill("Długa treść powiadomienia zajmująca kilka linii.").join("\n")});
                tryCompare(card,"expandable",true);
                const before=card.height;
                mouseClick(card,2,2);
                compare(card.expanded,true);
                compare(actions.count,0);
                wait(40);
                verify(card.height>before);
                mouseClick(card,2,2);
                compare(actions.count,1);
                const arrow=findChild(card,"notificationExpand");
                verify(arrow.visible);
                mouseMove(arrow, arrow.width / 2, arrow.height / 2);
                wait(220);
                mouseClick(arrow);
                compare(card.expanded,false);
                compare(actions.count,1);
                mouseClick(arrow);
                compare(card.expanded,true);
                compare(actions.count,1);
            }
            function test_buttonsDoNotActivateCard() {
                mouseMove(card, 20, 20);
                wait(220);
                mouseClick(card, 2, 2); wait(220);
                verify(findChild(card,"notificationDiscard").enabled);
                mouseClick(findChild(card,"notificationDiscard"));
                compare(actions.count,0);
            }
            function test_keyboard() {
                card.forceActiveFocus(Qt.TabFocusReason); wait(60);
                keyClick(Qt.Key_Space);
                compare(actions.count,1);
            }
            function test_longTitle() {
                card.notification = Object.assign({},card.notification,{summary:Array(20).fill("Długi tytuł").join(" ")});
                tryCompare(card,"expandable",true);
                mouseClick(card,2,2);
                compare(card.expanded,true);
                compare(actions.count,0);
                mouseClick(card,2,2);
                compare(actions.count,1);
            }
            function test_secondaryAction() {
                card.notification = Object.assign({},card.notification,{actions:[{id:"secondary",text:"Wykonaj"}]});
                wait(220);
                const button=findChild(card,"notificationAction_secondary");
                verify(!!button);
                mouseClick(button);
                compare(actions.count,1);
                compare(actions.signalArguments[0][0],"secondary");
            }
            function test_clickControls() {
                const discard = findChild(card, "notificationDiscard");
                const controls = findChild(card, "notificationControls");
                const height = card.height;
                compare(card.background.border.width, 0);
                compare(controls.opacity, 0);
                verify(!discard.enabled);
                mouseMove(card, 20, 20); wait(240);
                compare(controls.opacity, 0);
                compare(card.height, height);
                mouseClick(card, 20, 20);
                wait(60);
                verify(controls.opacity > 0 && controls.opacity < 1, "Missing controls fade-in");
                wait(180);
                compare(card.background.border.width, 0);
                compare(controls.opacity, 1);
                verify(discard.enabled);
                verify(card.height >= height + discard.height, "Card did not expand for its footer");
                mouseMove(discard, discard.width / 2, discard.height / 2);
                wait(220);
                compare(controls.opacity, 1);
                mouseMove(window.contentItem, window.width - 1, window.height - 1);
                wait(220);
                compare(card.background.border.width, 0);
                compare(controls.opacity, 1);
                verify(discard.enabled);
                card.controlsOpen = false; wait(220);
                compare(card.height, height);
            }
            function test_keyboardControls() {
                card.notification = Object.assign({}, card.notification, {actions:[{id:"secondary",text:"Wykonaj"}]});
                wait(40);
                const discard = findChild(card, "notificationDiscard");
                const controls = findChild(card, "notificationControls");
                keyClick(Qt.Key_Tab);
                wait(220);
                verify(card.keyboardFocusWithin && discard.enabled, "Card keyboard focus: " + card.keyboardFocusWithin
                    + ", visual: " + card.visualFocus + ", active: " + card.activeFocus + ", reason: " + card.focusReason + ", discard: " + discard.enabled);
                compare(controls.opacity, 1);
                const secondary = findChild(card, "notificationAction_secondary");
                secondary.forceActiveFocus(Qt.TabFocusReason);
                wait(220);
                verify(card.keyboardFocusWithin && discard.enabled, "Secondary action keyboard focus was not retained");
                discard.forceActiveFocus(Qt.TabFocusReason);
                wait(220);
                verify(discard.activeFocus && discard.enabled, "Discard keyboard focus was not retained");
                compare(card.background.border.width, 0);
                focusSink.forceActiveFocus(Qt.OtherFocusReason);
                wait(220);
                compare(controls.opacity, 0);
            }
            function test_toastLongCard() {
                card.toast = true;
                test_longCard();
            }
            function test_clearConfirmation() {
                card.visible = false;
                NotificationService._records = [NotificationService.normalize(card.notification)];
                centerLoader.active = true;
                wait(220);
                const center = centerLoader.item;
                const confirmation = findChild(center, "notificationClearConfirmation");
                const clear = findChild(center, "notificationClear");
                verify(confirmation.opacity === 0, "Confirmation initially visible");
                mouseMove(clear, clear.width / 2, clear.height / 2);
                mouseClick(clear);
                wait(60);
                verify(confirmation.opacity > 0 && confirmation.opacity < 1, "Missing confirmation fade-in");
                wait(180);
                compare(confirmation.opacity, 1);
                verify(confirmation.height > 0);
                const cancel = findChild(center, "notificationCancelClear");
                mouseMove(cancel, cancel.width / 2, cancel.height / 2);
                mouseClick(cancel);
                verify(!center.confirmingClear, "Cancel did not dismiss confirmation: " + cancel.width + "x" + cancel.height);
                wait(60);
                verify(confirmation.opacity > 0 && confirmation.opacity < 1, "Missing confirmation fade-out");
                verify(!confirmation.enabled);
                wait(180);
                verify(confirmation.opacity === 0, "Confirmation did not finish hiding");
                compare(confirmation.implicitHeight, 0);
                verify(!confirmation.visible);
                centerLoader.active = false;
                NotificationService._records = [];
                card.visible = true;
            }
            function test_toastGeometry() {
                card.toast = true;
                card.managedReveal = true;
                wait(220);
                const initial = card.height;
                for (const opening of [true, false]) {
                    let previous = card.height;
                    const samples = [previous];
                    card.revealSelected = opening;
                    for (let i = 0; i < 16; i++) {
                        wait(16);
                        const current = card.height;
                        verify(opening ? current >= previous : current <= previous,
                            "Toast edge reversed direction: " + previous + " -> " + current);
                        samples.push(current);
                        previous = current;
                    }
                    // Near the ends, eased movement is small. Layout spacing must
                    // not appear/disappear as an extra 8 px step.
                    verify(Math.abs(samples[1] - samples[0]) < 6, "Toast spacing jumped at animation start");
                    const target = samples[samples.length - 1];
                    let lastMoving = samples.length - 1;
                    while (lastMoving >= 0 && samples[lastMoving] === target) lastMoving--;
                    if (lastMoving >= 0)
                        verify(Math.abs(samples[lastMoving] - target) < 6, "Toast spacing jumped at animation end");
                }
                compare(card.height, initial);
                mouseMove(card, 20, 20);
                wait(220);
                verify(!card.controlsRevealed, "Managed hover changed from card geometry");
            }
            function test_longTextAnimation() {
                card.controlsOpen = true;
                card.notification = Object.assign({}, card.notification, {
                    summary: Array(5).fill("Dłuższy tytuł powiadomienia").join("\n"),
                    body: Array(14).fill("Dłuższy wiersz treści powiadomienia").join("\n")
                });
                mouseMove(card, 20, 20);
                wait(260);
                const body = findChild(card, "notificationBody");
                const fullText = findChild(body, "notificationFullText");
                const arrow = findChild(card, "notificationExpand");
                const compact = card.height;
                verify(!fullText.active, "Full text loaded while collapsed");
                for (const opening of [true, false]) {
                    const start = card.height;
                    mouseClick(opening ? card : arrow, 2, 2);
                    let previous = start;
                    let intermediate = false;
                    for (let i = 0; i < 20; i++) {
                        wait(16);
                        const height = card.height;
                        verify(opening ? height >= previous : height <= previous,
                            "Long text edge reversed: " + previous + " -> " + height);
                        if (body.expansion > 0 && body.expansion < 1) {
                            intermediate = true;
                            verify(fullText.active, "Full text released before collapse completed");
                        }
                        previous = height;
                    }
                    verify(intermediate, "Long text changed height without animation");
                    compare(body.expansion, opening ? 1 : 0);
                }
                compare(card.height, compact);
                verify(!fullText.active, "Full text retained after collapse");
                card.expanded = true;
                wait(80);
                const partial = card.height;
                const partialProgress = body.expansion;
                card.expanded = false;
                wait(32);
                verify(card.height <= partial && card.height > compact && body.expansion < partialProgress, "Interrupted collapse jumped");
                wait(260);
                compare(card.height, compact);
                Settings.reducedMotion = true;
                card.expanded = true;
                wait(32);
                compare(body.expansion, 1);
                card.expanded = false;
                wait(32);
                compare(body.expansion, 0);
                Settings.reducedMotion = false;
            }
            function test_toastControls() {
                card.toast = true;
                wait(220);
                test_clickControls();
                verify(card.background.color.a > 0.5);
            }
        }
    }
}
