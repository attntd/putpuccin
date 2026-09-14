//@ pragma ShellId notification-center-test
import QtQuick
import QtQuick.Window
import QtTest
import Quickshell
import Quickshell.Io
import qs.core
import qs.services
import qs.modules.statusbar
import qs.modules.notifications
ShellRoot {
    Window {
        id: window
        visible: true
        width: 450
        height: 1300
        Item { id: sink; x: 440; y: 1290; width: 10; height: 10 }
        QtObject { id: bar; function activateNotificationSearch() {} }
        NotificationsModule {
            id: module
            visible: false
            shellScreen: ({name:"test", height:1300})
            barWindow: bar
        }
        Loader {
            id: loader
            width: 410
            sourceComponent: module.expansionComponent
        }
        TestCase {
            id: tests
            when: false
            function check(ok, message) { if (!ok) throw new Error(message); }
            function card(index) { return findChild(loader.item, "notificationCard_n" + index); }
            function run() {
                loader.active = false;
                Settings.topMargin = 8;
                Settings.notificationCenterHeightFraction = 1;
                module.shellScreen = {name:"test", height:1300};
                wait(250);
                const records = [];
                for (let i = 1; i <= 5; i++) records.push(NotificationService.normalize({uid:"n" + i,
                    appName:"Grupa " + Math.ceil(i / 2), summary:"Kafelek " + i,
                    body:"Kontrola dolnej krawędzi", time:Date.now(), actions:[]}));
                NotificationService._records = records;
                loader.active = true;
                const center = loader.item;
                center.expandedGroups = {"Grupa 1":true, "Grupa 2":true};
                sink.forceActiveFocus(Qt.OtherFocusReason);
                mouseMove(sink, 5, 5);
                wait(240);
                const list = findChild(center, "notificationList");
                check(!!card(5), "Last card is not loaded: " + JSON.stringify({groups:center.displayedUids,height:center.height,listHeight:list.height,content:list.contentHeight,count:list.count}));
                mouseMove(card(1), 20, 20); wait(240);
                check(center.clickedUid === "" && card(1).stackRevealProgress === 0, "Hover revealed controls");
                mouseClick(card(1), 20, 20);
                wait(240);
                const bottom = card(5).mapToItem(window.contentItem, 0, card(5).height).y;
                const panelHeight = center.height;
                function stable() {
                    let total = 0;
                    for (let i = 1; i <= 5; i++) total += card(i).stackRevealProgress;
                    check(Math.abs(total - 1) < 0.00001, "Unsynchronized reveals: " + total);
                    check(waitForPolish(window, 500), "Layout polish did not settle");
                    const edge = card(5).mapToItem(window.contentItem, 0, card(5).height).y;
                    check(Math.abs(edge - bottom) < 0.01, "Bottom moved: " + bottom + " -> " + edge);
                    check(Math.abs(center.height - panelHeight) < 0.01, "Panel moved: " + panelHeight + " -> " + center.height);
                }
                let previous = 1;
                for (const index of [2,3,4,5,4,3,2,1]) {
                    const upper = card(Math.min(previous, index));
                    const lower = card(Math.max(previous, index));
                    const start = upper.mapToItem(list, 20, upper.height);
                    const end = lower.mapToItem(list, 20, 0);
                    mouseMove(list, 20, (start.y + end.y) / 2);
                    wait(30);
                    stable();
                    mouseMove(card(index), 20, 20);
                    mouseClick(card(index), 20, 20);
                    for (let i = 0; i < 14; i++) { wait(16); stable(); }
                    check(center.clickedUid === "n" + index, "Hover changed under stationary pointer");
                    previous = index;
                }
                for (const index of [2,5,1,4,3,1]) {
                    mouseMove(card(index), 20, 20);
                    mouseClick(card(index), 20, 20);
                    wait(40);
                    stable();
                }
                wait(240);
                mouseMove(sink, 5, 5);
                wait(240);
                check(center.clickedUid === "n1", "Pointer exit changed click selection");
                center.clickedUid = ""; wait(240);
                card(2).forceActiveFocus(Qt.TabFocusReason);
                wait(240);
                check(center.selectedUid === "n2" && card(2).stackRevealProgress === 1, "Keyboard did not reveal controls");
                keyClick(Qt.Key_J); wait(250);
                check(card(3).activeFocus, "J did not cross the group boundary");
                keyClick(Qt.Key_K); wait(250);
                check(card(2).activeFocus, "K did not return across the group boundary");
                keyClick(Qt.Key_L); wait(50);
                check(!card(2).activeFocus && card(2).keyboardFocusWithin, "L did not reach notification actions");
                keyClick(Qt.Key_H); wait(50);
                check(card(2).activeFocus, "H did not return from notification actions");
                const discard = findChild(card(2), "notificationDiscard");
                discard.forceActiveFocus(Qt.TabFocusReason);
                wait(80);
                check(discard.enabled && discard.activeFocus, "Discard lost keyboard focus");
                sink.forceActiveFocus(Qt.OtherFocusReason);
                wait(240);
                check(center.selectedUid === "", "Keyboard reveal did not reset");
                mouseClick(card(3), 20, 20);
                wait(240);
                const search = findChild(center, "notificationSearch");
                search.text = "Kafelek 1";
                wait(240);
                check(center.clickedUid === "" && center.displayedUids.length === 1, "Filtering retained removed hover");
                search.text = "";
                wait(240);
                NotificationService._records = records.map(r => r.uid === "n3"
                    ? Object.assign({}, r, {body:Array(60).fill("Pełna treść długiego powiadomienia").join("\n")}) : r);
                wait(180);
                const longCard = card(3);
                center.clickedUid = "n3";
                mouseMove(longCard, 20, 20);
                wait(240);
                const initialHeight = center.height;
                mouseClick(longCard, 2, 2);
                let intermediateHeight = false;
                for (let i = 0; i < 20; i++) {
                    wait(16);
                    check(center.height <= center.maximumHeight + 0.01, "Long text exceeds panel cap");
                    if (center.height > initialHeight && center.height < center.maximumHeight)
                        intermediateHeight = true;
                }
                check(intermediateHeight && Math.abs(center.height - center.maximumHeight) < 0.01,
                    "Long text did not smoothly reach the screen limit");
                check(list.contentHeight > list.height, "Expanded long text cannot be scrolled");
                list.positionViewAtEnd();
                wait(120);
                longCard.expanded = false;
                wait(320);
                check(center.height < center.maximumHeight, "Collapsed long text retained full panel height");
                list.positionViewAtBeginning();
                NotificationService._records = records;
                wait(120);
                const many = [];
                for (let i = 1; i <= 30; i++) many.push(NotificationService.normalize({uid:"cap" + i,
                    appName:"Aplikacja " + i, summary:"Limit panelu", body:"Treść", time:Date.now(), actions:[]}));
                NotificationService._records = many;
                for (const screenHeight of [600,900,1500]) {
                    for (const margin of [8,20]) {
                        Settings.topMargin = margin;
                        module.shellScreen = {name:"test", height:screenHeight};
                        wait(100);
                        check(Math.abs(margin + Settings.barHeight + center.height + margin - screenHeight) < 0.01,
                            "Panel does not preserve matching screen margins");
                        check(list.contentHeight > list.height, "Overflow is not scrollable");
                    }
                }
                NotificationService._records = [records[0]];
                wait(180);
                check(center.height < center.maximumHeight && list.contentHeight <= list.height + 0.01,
                    "Small history should fit without scrolling");
                Settings.topMargin = 8;
                module.shellScreen = {name:"test", height:1300};
                NotificationService._records = records;
                wait(180);
                center.maximumHeight = 360;
                wait(240);
                mouseMove(list, 20, 80);
                list.flick(0, -900);
                wait(180);
                check(list.contentY > 0, "List did not scroll");
                check(center.clickedUid !== "n1", "Scrolling retained first card");
                list.cancelFlick();
                mouseMove(sink, 5, 5);
                wait(240);
                NotificationService._records = Array.from({length: 24}, (_, index) =>
                    NotificationService.normalize({uid: "long" + index, appName: "App " + index,
                        summary: "Powiadomienie " + index, body: "Test przewijania", time: Date.now(), actions: []}));
                wait(250);
                const uids = center.displayedUids.slice();
                center.focusNotification(uids[0]); wait(100);
                for (let i = 1; i < uids.length; i++) {
                    keyClick(Qt.Key_J); wait(30);
                    const selected = findChild(center, "notificationCard_" + uids[i]);
                    check(selected && selected.activeFocus, "J lost virtualized notification " + i);
                }
                check(list.contentY > 0, "J did not scroll the long notification history");
                for (let i = uids.length - 2; i >= 0; i--) {
                    keyClick(Qt.Key_K); wait(30);
                    const selected = findChild(center, "notificationCard_" + uids[i]);
                    check(selected && selected.activeFocus, "K lost virtualized notification " + i);
                }
                loader.active = false;
                NotificationService._records = [];
                return true;
            }
        }
    }
    IpcHandler {
        target: "centertest"
        function run(): string {
            try { return JSON.stringify({passed:tests.run()}); }
            catch (e) { return JSON.stringify({passed:false, error:String(e)}); }
        }
    }
}
