pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import QtMultimedia
import QtQml.Models
import Quickshell
import Quickshell.Hyprland
import Quickshell.Services.Notifications
import qs.core

Singleton {
    id: root

    // Only commands below mutate domain state. UI never owns a native handle.
    readonly property var records: _records
    readonly property var toasts: _toasts
    readonly property var visibleToasts: _toastViews
    property var _toastViews: []
    readonly property bool dnd: _dnd
    readonly property bool hasNew: _hasNew
    readonly property int count: _records.length
    readonly property string undoScreen: _undoScreen
    property string _undoScreen: ""
    readonly property bool canUndo: _undo !== null
    readonly property string errorMessage: history.errorMessage || _activationError
    readonly property string state: history.ready ? (errorMessage ? "error" : "ready") : "loading"
    readonly property bool available: history.ready
    readonly property string tooltip: dnd ? Strings.notificationsDnd : Strings.notifications
    property var _records: []
    property var _toasts: []
    property var _live: ({})
    property var _pending: []
    property var _discardedIds: []
    property var _centers: ({})
    property var _focusOrder: ({})
    property var _undo: null
    property bool _dnd: false
    property bool _hasNew: false
    property double _lastSoundTime: 0
    property string _activationError: ""

    function playNotificationSound(n) {
        const now = Date.now();
        if (!Settings.notificationSoundEnabled || _dnd || (n.hints || {})["suppress-sound"]
                || now - _lastSoundTime < 800 || notificationSound.playing)
            return;
        _lastSoundTime = now;
        notificationSound.play();
    }

    SoundEffect {
        id: notificationSound
        objectName: "notificationSound"
        source: Qt.resolvedUrl("../assets/sounds/notification.wav")
        volume: 0.4
    }

    function persist() {
        if (!history.ready)
            return;
        const recordIds = new Set(_records.map(r => r.uid));
        const data = {schemaVersion: 1, dnd: _dnd, hasNew: _hasNew, processId: Quickshell.processId,
            discardedIds: Object.keys(_live).filter(uid => !recordIds.has(uid)).map(uid => _live[uid].id),
            records: _records.filter(r => !r.transient).map(r => {
                const copy = Object.assign({}, r);
                delete copy.image;
                // Action identifiers are never persisted: they belong to a live sender.
                delete copy.actions;
                delete copy.hasInlineReply;
                delete copy.inlineReplyPlaceholder;
                return copy;
            })};
        handoff.snapshot = JSON.stringify(data);
        history.schedule(data);
    }

    function normalize(value) {
        if (!value || typeof value !== "object" || typeof value.uid !== "string"
                || !Number.isFinite(value.time) || value.time > Date.now() + 60000)
            return null;
        const clean = {};
        for (const key of ["uid", "appName", "summary", "body", "appIcon", "desktopEntry"])
            clean[key] = typeof value[key] === "string" ? value[key].slice(0, key === "body" ? 32768 : 2048) : "";
        const origin = value.origin;
        clean.origin = origin && typeof origin === "object" && typeof origin.address === "string"
            && /^[0-9a-f]+$/.test(origin.address) && Number.isInteger(origin.pid) && origin.pid > 0
            && origin.session === Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE")
            ? {address: origin.address, pid: origin.pid, session: origin.session} : null;
        clean.time = value.time;
        clean.serverId = Number(value.serverId) || 0;
        clean.processId = Number(value.processId) || 0;
        clean.urgency = Number(value.urgency) || 0;
        clean.transient = false;
        clean.image = "";
        clean.actions = [];
        clean.hasInlineReply = false;
        clean.inlineReplyPlaceholder = "";
        return clean;
    }

    function record(uid) { return _records.find(r => r.uid === uid) || null; }
    function live(uid) { return _live[uid] || null; }
    function keyFor(n) {
        return Object.keys(_live).find(key => _live[key] === n) || "";
    }

    function snapshot(n, uid, timestamp) {
        // libnotify puts -i theme icons in image-path. Keep those in the header,
        // reserving the attachment area for actual images and avatars.
        const nativeImage = String(n.image || "");
        const imageIcon = nativeImage.startsWith("image://icon/") ? nativeImage.slice(13) : "";
        return {uid: uid, serverId: n.id, processId: Quickshell.processId,
            origin: record(uid) ? record(uid).origin : null,
            appName: String(n.appName || n.desktopEntry || Strings.notificationsUnknownApp).slice(0, 2048),
            summary: String(n.summary || "").slice(0, 2048), body: String(n.body || "").slice(0, 32768),
            appIcon: String(n.appIcon || imageIcon || "").slice(0, 2048), desktopEntry: String(n.desktopEntry || "").slice(0, 2048),
            image: imageIcon ? "" : nativeImage, urgency: Number(n.urgency), transient: n.transient,
            time: timestamp, actions: (n.actions || []).map(a => ({id: a.identifier, text: a.text})),
            hasInlineReply: n.hasInlineReply,
            inlineReplyPlaceholder: String(n.inlineReplyPlaceholder || "").slice(0, 2048)};
    }

    function accept(n) {
        n.tracked = true;
        if (!history.ready) {
            _pending = _pending.concat([n]);
            return;
        }
        if (n.lastGeneration && _discardedIds.indexOf(n.id) >= 0) {
            n.dismiss();
            return;
        }
        let restored = n.lastGeneration ? _records.find(r => r.serverId === n.id && r.processId === Quickshell.processId) : null;
        const uid = restored ? restored.uid : Date.now() + "-" + Quickshell.processId + "-" + n.id;
        const map = Object.assign({}, _live);
        map[uid] = n;
        _live = map;
        const item = snapshot(n, uid, restored ? restored.time : Date.now());
        _records = [item].concat(_records.filter(r => r.uid !== uid));
        _records = _records.slice().sort((a, b) => b.time - a.time);
        prune();
        if (!n.lastGeneration) {
            playNotificationSound(n);
            const screen = focusedScreen();
            if (!_centers[screen])
                _hasNew = true;
            showToast(uid, screen);
        }
        persist();
    }

    function update(n) {
        const uid = keyFor(n);
        if (!uid || !record(uid))
            return;
        _records = [snapshot(n, uid, Date.now())].concat(_records.filter(r => r.uid !== uid));
        const oldToast = _toasts.find(t => t.uid === uid);
        const screen = oldToast ? oldToast.screen : focusedScreen();
        if (!_centers[screen])
            _hasNew = true;
        if (oldToast) {
            // Keep the presentation UID and pause while an editor is open.
            // Removing/reinserting it would discard focus and the reply draft.
            const duration = Number(n.urgency) === 2 ? 0 : Settings.notificationToastDuration;
            _toasts = _toasts.map(t => t.uid === uid ? Object.assign({}, t, {
                remaining: duration, deadline: duration && !t.paused ? Date.now() + duration : 0
            }) : t);
            scheduleToasts();
        } else {
            showToast(uid, screen);
        }
        prune();
        persist();
    }

    function closed(n) {
        const uid = keyFor(n);
        if (!uid)
            return;
        hideToast(uid);
        const map = Object.assign({}, _live);
        delete map[uid];
        _live = map;
        _records = _records.filter(r => r.uid !== uid || !r.transient)
            .map(r => r.uid === uid ? Object.assign({}, r, {actions: [], image: "", hasInlineReply: false, inlineReplyPlaceholder: ""}) : r);
        if (_undo && _undo.uid === uid)
            _undo = _undo.transient ? null : Object.assign({}, _undo, {actions: [], image: "", hasInlineReply: false, inlineReplyPlaceholder: ""});
        persist();
    }

    function reply(uid, text) {
        const n = live(uid);
        if (typeof text !== "string" || !text.trim() || text.length > 32768
                || !record(uid) || !n || !n.tracked || !n.hasInlineReply)
            return false;
        // Native NotificationReplied goes back to the notification client.
        // There is no delivery acknowledgement; never persist the reply text.
        n.sendInlineReply(text);
        hideToast(uid);
        return true;
    }

    function retire(uid) {
        const n = live(uid);
        if (n)
            n.dismiss();
    }

    function prune() {
        const minimum = Date.now() - Settings.notificationHistoryDays * 86400000;
        const keep = _records.filter(r => r.time >= minimum).slice(0, Settings.notificationHistoryLimit);
        const keepIds = new Set(keep.map(r => r.uid));
        const removed = _records.filter(r => !keepIds.has(r.uid));
        _records = keep;
        if (!keep.length)
            _hasNew = false;
        for (const r of removed) {
            hideToast(r.uid);
            retire(r.uid);
        }
        retention.stop();
        if (keep.length) {
            retention.interval = Math.max(1, Math.min(2147483647,
                Math.min.apply(null, keep.map(r => r.time)) + Settings.notificationHistoryDays * 86400000 - Date.now() + 1));
            retention.start();
        }
        persist();
    }

    function focusedScreen() {
        const focused = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : "";
        return Quickshell.screens.some(s => s.name === focused) ? focused
            : Quickshell.screens.length ? Quickshell.screens[0].name : "";
    }

    function showToast(uid, screen) {
        if (_dnd || _centers[screen] || _toasts.length >= Settings.notificationMaxToasts)
            return;
        const r = record(uid);
        if (!r)
            return;
        const duration = r.urgency === 2 ? 0 : Settings.notificationToastDuration;
        _toasts = _toasts.concat([{uid: uid, screen: screen, remaining: duration,
            deadline: duration ? Date.now() + duration : 0, paused: false}]);
        scheduleToasts();
    }

    function hideToast(uid) {
        _toasts = _toasts.filter(t => t.uid !== uid);
        scheduleToasts();
    }

    function pauseToast(uid, paused) {
        _toasts = _toasts.map(t => {
            if (t.uid !== uid || t.paused === paused)
                return t;
            const remaining = paused && t.deadline ? Math.max(1, t.deadline - Date.now()) : t.remaining;
            return Object.assign({}, t, {paused: paused, remaining: remaining,
                deadline: paused || !remaining ? 0 : Date.now() + remaining});
        });
        scheduleToasts();
    }

    function scheduleToasts() {
        const views = _toasts.map(t => ({uid: t.uid, screen: t.screen}));
        // Stable presentation model: pausing a deadline must not recreate the
        // hovered item (which could in turn generate another hover event).
        if (JSON.stringify(views) !== JSON.stringify(_toastViews))
            _toastViews = views;
        toastClock.stop();
        const deadlines = _toasts.filter(t => t.deadline > 0).map(t => t.deadline);
        if (deadlines.length) {
            toastClock.interval = Math.max(1, Math.min.apply(null, deadlines) - Date.now());
            toastClock.start();
        }
    }

    function setCenterOpen(screen, open) {
        const map = Object.assign({}, _centers);
        if (open) {
            map[screen] = true;
            _hasNew = false;
            _toasts = _toasts.filter(t => t.screen !== screen);
            scheduleToasts();
        } else {
            delete map[screen];
        }
        _centers = map;
        if (open)
            prune();
        persist();
    }

    function setDnd(value) {
        _dnd = value;
        if (value) {
            _toasts = [];
            scheduleToasts();
        }
        persist();
    }
    function toggleDnd() { setDnd(!_dnd); }

    function finishUndo() {
        if (!_undo)
            return;
        const uid = _undo.uid;
        _undo = null;
        undoClock.stop();
        retire(uid);
    }
    function discard(uid) {
        const r = record(uid);
        if (!r)
            return;
        finishUndo();
        _undoScreen = (_toasts.find(t => t.uid === uid) || {}).screen || focusedScreen();
        _undo = r;
        hideToast(uid);
        _records = _records.filter(item => item.uid !== uid);
        if (!_records.length)
            _hasNew = false;
        undoClock.restart();
        persist();
    }
    function undo() {
        if (!_undo)
            return;
        _records = _records.concat([_undo]).sort((a, b) => b.time - a.time);
        _undo = null;
        undoClock.stop();
        prune();
    }
    // The center requires explicit inline confirmation before calling this.
    function clearAll() {
        finishUndo();
        const old = _records;
        _records = [];
        _toasts = [];
        _hasNew = false;
        scheduleToasts();
        retention.stop();
        for (const r of old)
            retire(r.uid);
        persist();
    }

    function groups(query) {
        const needle = String(query || "").trim().toLocaleLowerCase();
        const groups = [];
        const index = new Map();
        for (const r of _records) {
            if (needle && (r.appName + " " + r.summary + " " + r.body).toLocaleLowerCase().indexOf(needle) < 0)
                continue;
            const key = r.desktopEntry || r.appName;
            let group = index.get(key);
            if (!group) {
                group = {key: key, name: r.appName, records: []};
                groups.push(group);
                index.set(key, group);
            }
            group.records.push(r);
        }
        return groups;
    }

    function normalizedId(value) { return String(value || "").replace(/\.desktop$/, "").toLocaleLowerCase(); }
    function entryFor(r) {
        const id = normalizedId(r.desktopEntry);
        const entries = DesktopEntries.applications.values;
        if (id) {
            const exact = entries.filter(e => normalizedId(e.id) === id);
            if (exact.length === 1)
                return exact[0];
        }
        const name = normalizedId(r.appName);
        const matches = entries.filter(e => normalizedId(e.name) === name || normalizedId(e.id) === name
            || (e.startupClass && normalizedId(e.startupClass) === name));
        return matches.length === 1 ? matches[0] : null;
    }
    function matchesWindow(r, entry, w) {
        const ipc = w.lastIpcObject || {};
        const classes = [ipc.class, ipc.initialClass, w.wayland ? w.wayland.appId : ""].map(normalizedId).filter(x => x);
        const ids = [r.desktopEntry, entry ? entry.id : "", entry ? entry.startupClass : ""].map(normalizedId).filter(x => x);
        // An exact app name/class match identifies an existing window, but never
        // supplies a command to execute when there is no recognized desktop entry.
        if (!ids.length)
            ids.push(normalizedId(r.appName));
        return classes.some(c => ids.indexOf(c) >= 0);
    }
    function focusRank(w) {
        if (_focusOrder[w.address])
            return _focusOrder[w.address];
        const order = Number((w.lastIpcObject || {}).focusHistoryID);
        return Number.isFinite(order) ? -order : -1000000;
    }
    function originWindow(r) {
        const origin = r.origin;
        if (!origin || origin.session !== Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE"))
            return null;
        return Hyprland.toplevels.values.find(w => w.address === origin.address
            && Number((w.lastIpcObject || {}).pid) === origin.pid) || null;
    }
    function focusWindow(w) {
        // The compositor dispatcher focuses explicitly; a Wayland activate()
        // request can be reduced to urgency when focus_on_activate is disabled.
        if (!/^[0-9a-f]+$/.test(w.address))
            return;
        const selector = "address:0x" + w.address;
        if (Hyprland.usingLua)
            Hyprland.dispatch("hl.dsp.focus({ window = " + JSON.stringify(selector) + " })");
        else
            Hyprland.dispatch("focuswindow " + selector);
    }
    function rememberOrigin(r, w) {
        const pid = Number((w.lastIpcObject || {}).pid);
        if (!Number.isInteger(pid) || pid <= 0)
            return;
        const origin = {address: w.address, pid: pid,
            session: Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE")};
        _records = _records.map(item => item.uid === r.uid ? Object.assign({}, item, {origin: origin}) : item);
        persist();
    }
    function activationRequested(address) {
        // Hyprland can mark an application's xdg-activation request urgent instead
        // of focusing it. During a user-invoked default action this identifies the
        // actual source window, including when several Kitty windows are open.
        if (!activationFallback.running || !activationFallback.item)
            return;
        const r = activationFallback.item;
        const w = Hyprland.toplevels.values.find(w => w.address === String(address).replace(/^0x/, ""));
        if (!w || !w.wayland || !matchesWindow(r, entryFor(r), w))
            return;
        activationFallback.stop();
        rememberOrigin(r, w);
        focusWindow(w);
    }
    function fallback(r) {
        const origin = originWindow(r);
        if (origin && origin.wayland) {
            focusWindow(origin);
            _activationError = "";
            return;
        }
        const entry = entryFor(r);
        const windows = Hyprland.toplevels.values.filter(w => matchesWindow(r, entry, w));
        windows.sort((a, b) => focusRank(b) - focusRank(a));
        if (windows.length && windows[0].wayland) {
            focusWindow(windows[0]);
            _activationError = "";
            return;
        }
        if (entry) {
            entry.execute();
            _activationError = "";
            return;
        }
        _activationError = Strings.notificationsCannotActivate;
    }
    function activate(uid, actionId) {
        const r = record(uid);
        if (!r)
            return;
        hideToast(uid);
        _activationError = "";
        // Newly opened toplevels initially have only event metadata (no PID).
        Hyprland.refreshToplevels();
        activationFallback.stop();
        const n = live(uid);
        const action = n ? n.actions.find(a => a.identifier === (actionId || "default")) : null;
        if (action) {
            if (!actionId || actionId === "default") {
                activationFallback.item = r;
                activationFallback.address = Hyprland.activeToplevel ? Hyprland.activeToplevel.address : "";
                activationFallback.start();
            }
            // invoke() may synchronously close the notification; r is a snapshot.
            action.invoke();
        } else if (!actionId || actionId === "default") {
            fallback(r);
        }
    }

    // Transfer the latest snapshot before the disk debounce when QML reloads.
    // No QObject/action references cross generations through this object.
    PersistentProperties {
        id: handoff
        reloadableId: "notification-history-handoff"
        property string snapshot: ""
    }
    NotificationHistory {
        id: history
        onLoaded: data => {
            if (handoff.snapshot) {
                try { data = JSON.parse(handoff.snapshot); } catch (error) {}
            }
            root._discardedIds = data.processId === Quickshell.processId && Array.isArray(data.discardedIds) ? data.discardedIds : [];
            root._dnd = data.dnd === true;
            root._hasNew = data.hasNew === true;
            const seen = {};
            root._records = (Array.isArray(data.records) ? data.records : []).map(root.normalize).filter(r => {
                if (!r || seen[r.uid])
                    return false;
                seen[r.uid] = true;
                return true;
            }).sort((a, b) => b.time - a.time);
            root.prune();
            const pending = root._pending;
            root._pending = [];
            for (const n of pending)
                if (n && n.tracked)
                    root.accept(n);
        }
    }

    NotificationServer {
        id: server
        actionsSupported: true
        bodySupported: true
        imageSupported: true
        persistenceSupported: true
        bodyMarkupSupported: false
        bodyHyperlinksSupported: false
        bodyImagesSupported: false
        inlineReplySupported: true
        keepOnReload: true
        onNotification: notification => root.accept(notification)
    }

    Instantiator {
        model: server.trackedNotifications
        delegate: QtObject {
            id: observer
            required property var modelData
            property Timer changed: Timer {
                interval: 0
                onTriggered: root.update(observer.modelData)
            }
            property Connections signals: Connections {
                target: observer.modelData
                function onSummaryChanged() { observer.changed.restart(); }
                function onBodyChanged() { observer.changed.restart(); }
                function onAppNameChanged() { observer.changed.restart(); }
                function onAppIconChanged() { observer.changed.restart(); }
                function onImageChanged() { observer.changed.restart(); }
                function onDesktopEntryChanged() { observer.changed.restart(); }
                function onUrgencyChanged() { observer.changed.restart(); }
                function onTransientChanged() { observer.changed.restart(); }
                function onHintsChanged() { observer.changed.restart(); }
                function onExpireTimeoutChanged() { observer.changed.restart(); }
                function onActionsChanged() { observer.changed.restart(); }
                function onHasInlineReplyChanged() { observer.changed.restart(); }
                function onInlineReplyPlaceholderChanged() { observer.changed.restart(); }
                function onClosed(reason) { observer.changed.stop(); root.closed(observer.modelData); }
            }
        }
    }
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name === "urgent")
                root.activationRequested(event.data);
            else if (event.name === "closewindow") {
                // A compositor address may be reused by another window later.
                const address = event.data.replace(/^0x/, "");
                if (root._records.some(r => r.origin && r.origin.address === address)) {
                    root._records = root._records.map(r => r.origin && r.origin.address === address
                        ? Object.assign({}, r, {origin: null}) : r);
                    root.persist();
                }
            }
        }
        function onActiveToplevelChanged() {
            const active = Hyprland.activeToplevel;
            if (active) {
                const map = {};
                for (const w of Hyprland.toplevels.values)
                    map[w.address] = root._focusOrder[w.address] || 0;
                map[active.address] = Date.now();
                root._focusOrder = map;
                if (activationFallback.running && active.address !== activationFallback.address) {
                    const r = activationFallback.item;
                    if (r && root.matchesWindow(r, root.entryFor(r), active))
                        root.rememberOrigin(r, active);
                    activationFallback.stop();
                }
            }
        }
    }
    Connections {
        target: Quickshell
        function onScreensChanged() {
            const names = Quickshell.screens.map(s => s.name);
            const destination = root.focusedScreen();
            if (names.indexOf(root._undoScreen) < 0)
                root._undoScreen = destination;
            root._toasts = root._toasts.map(t => names.indexOf(t.screen) >= 0 ? t : Object.assign({}, t, {screen: destination}))
                .filter(t => !root._centers[t.screen]);
            root.scheduleToasts();
        }
    }
    Connections {
        target: Settings
        function onNotificationHistoryDaysChanged() { if (history.ready) root.prune(); }
        function onNotificationHistoryLimitChanged() { if (history.ready) root.prune(); }
    }
    Timer {
        id: toastClock
        onTriggered: {
            root._toasts = root._toasts.filter(t => !t.deadline || t.deadline > Date.now());
            root.scheduleToasts();
        }
    }
    Timer { id: retention; onTriggered: root.prune() }
    Timer { id: undoClock; interval: 5000; onTriggered: root.finishUndo() }
    Timer {
        id: activationFallback
        property var item: null
        property string address: ""
        interval: 500
        onTriggered: {
            if (item && (!Hyprland.activeToplevel || Hyprland.activeToplevel.address === address))
                root.fallback(item);
            item = null;
        }
    }
    Component.onDestruction: root.persist()
}
