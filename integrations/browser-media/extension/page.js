"use strict";
(() => {
    // MAIN world is necessary because Media Session has setters, not change events.
    // Preserve native semantics and observe only the two authorized web players.
    const session = navigator.mediaSession;
    if (!session) return;
    const handlers = new Map();
    const watched = new WeakSet();
    let activeMedia = null;
    let declaredPosition = null;
    let observedTimeline = null;
    let lastSnapshot = "";
    let scheduled = false;
    let knownPlayer = false;

    const text = value => typeof value === "string" ? value.slice(0, 1024) : "";
    const finite = value => typeof value === "number" && Number.isFinite(value);
    const isSoundCloud = ["soundcloud.com", "www.soundcloud.com"].includes(location.hostname);

    function artwork() {
        for (const image of session.metadata?.artwork || []) {
            try {
                const url = new URL(image.src, location.href);
                if (url.protocol !== "https:" || url.username || url.password) continue;
                url.search = "";
                url.hash = "";
                return url.href;
            } catch {}
        }
        return "";
    }

    function position() {
        if (isSoundCloud && observedTimeline?.isConnected) {
            const max = observedTimeline.getAttribute("aria-valuemax");
            const now = observedTimeline.getAttribute("aria-valuenow");
            // SoundCloud's playbackTimeline exports whole seconds. Missing
            // attributes must stay unknown; Number(null) would fabricate zero.
            const duration = max?.trim() ? Number(max) : null;
            const current = now?.trim() ? Number(now) : null;
            if (finite(duration) && duration > 0 && finite(current) && current >= 0)
                return {duration, position: Math.min(duration, current), playbackRate: 1};
        }
        if (activeMedia && finite(activeMedia.duration) && activeMedia.duration > 0
                && finite(activeMedia.currentTime)) {
            return {duration: activeMedia.duration,
                position: Math.max(0, Math.min(activeMedia.duration, activeMedia.currentTime)),
                playbackRate: finite(activeMedia.playbackRate) ? activeMedia.playbackRate : 1};
        }
        if (declaredPosition) {
            const elapsed = session.playbackState === "playing"
                ? (performance.now() - declaredPosition.at) / 1000 * declaredPosition.playbackRate : 0;
            return {duration: declaredPosition.duration,
                position: Math.max(0, Math.min(declaredPosition.duration, declaredPosition.position + elapsed)),
                playbackRate: declaredPosition.playbackRate};
        }
        return {duration: null, position: null, playbackRate: 1};
    }

    function snapshot() {
        const metadata = session.metadata;
        const declared = session.playbackState;
        const playing = declared === "playing" || (declared === "none" && activeMedia
            && !activeMedia.paused && !activeMedia.ended);
        if (!knownPlayer && !(playing && (activeMedia || metadata))) return null;
        knownPlayer = true;
        const state = playing ? "Playing" : declared === "paused" || (activeMedia && !activeMedia.ended)
            ? "Paused" : "Stopped";
        const timeline = position();
        return {type: "update", sourceHost: location.hostname, pageTitle: text(document.title),
            title: text(metadata?.title || document.title), artist: text(metadata?.artist),
            album: text(metadata?.album), artUrl: artwork(), state, ...timeline,
            canPlay: handlers.has("play") || !!activeMedia,
            canPause: handlers.has("pause") || !!activeMedia,
            canNext: handlers.has("nexttrack"), canPrevious: handlers.has("previoustrack"),
            canSeek: timeline.duration !== null && (handlers.has("seekto") || !!activeMedia
                || (handlers.has("seekforward") && handlers.has("seekbackward")))};
    }

    function publish() {
        scheduled = false;
        const state = snapshot();
        if (!state) return;
        const serialized = JSON.stringify(state);
        if (serialized === lastSnapshot) return;
        lastSnapshot = serialized;
        window.postMessage({channel: "quickshell-media-state-v1", state}, location.origin);
    }

    function schedule() {
        if (!scheduled) {
            scheduled = true;
            queueMicrotask(publish);
        }
    }

    function watchMedia(media) {
        if (watched.has(media)) return;
        watched.add(media);
        const event = e => {
            if (e.type === "play" || e.type === "playing") activeMedia = media;
            if (activeMedia !== media) return;
            if (e.type === "emptied") declaredPosition = null;
            schedule();
        };
        for (const name of ["play", "playing", "pause", "ended", "emptied", "loadedmetadata",
            "durationchange", "timeupdate", "seeked", "ratechange"]) media.addEventListener(name, event);
        if (!media.paused && !media.ended) activeMedia = media;
    }

    const originalPlay = HTMLMediaElement.prototype.play;
    HTMLMediaElement.prototype.play = function (...args) {
        watchMedia(this); // Also sees elements kept outside the DOM by web players.
        return originalPlay.apply(this, args);
    };
    document.addEventListener("play", event => {
        if (event.target instanceof HTMLMediaElement) {
            watchMedia(event.target);
            activeMedia = event.target;
            schedule();
        }
    }, true);

    function observeSetter(prototype, name, changed) {
        const original = Object.getOwnPropertyDescriptor(prototype, name);
        if (!original?.get || !original.set || !original.configurable) return;
        Object.defineProperty(prototype, name, {...original, set(value) {
            const previous = original.get.call(this);
            original.set.call(this, value);
            changed?.(previous, value);
            schedule();
        }});
    }
    observeSetter(MediaSession.prototype, "metadata", (previous, value) => {
        if (previous?.title !== value?.title || previous?.artist !== value?.artist) {
            declaredPosition = null;
            if (activeMedia?.paused || activeMedia?.ended) activeMedia = null;
        }
    });
    observeSetter(MediaSession.prototype, "playbackState", previous => {
        // Freeze the last explicit position when a WebAudio source pauses.
        if (declaredPosition) {
            const now = performance.now();
            if (previous === "playing") declaredPosition.position = Math.max(0,
                Math.min(declaredPosition.duration, declaredPosition.position
                    + (now - declaredPosition.at) / 1000 * declaredPosition.playbackRate));
            declaredPosition.at = now;
        }
    });
    for (const key of ["title", "artist", "album", "artwork"])
        observeSetter(MediaMetadata.prototype, key);

    const originalHandler = MediaSession.prototype.setActionHandler;
    MediaSession.prototype.setActionHandler = function (action, callback) {
        const result = originalHandler.call(this, action, callback);
        if (this === session) {
            if (callback) handlers.set(action, callback); else handlers.delete(action);
            schedule();
        }
        return result;
    };
    const originalPosition = MediaSession.prototype.setPositionState;
    MediaSession.prototype.setPositionState = function (value) {
        const result = originalPosition.call(this, value);
        if (this === session) {
            declaredPosition = value && finite(value.duration) && value.duration > 0
                ? {duration: value.duration, position: value.position ?? 0,
                    playbackRate: value.playbackRate ?? 1, at: performance.now()} : null;
            schedule();
        }
        return result;
    };

    const timelineObserver = new MutationObserver(schedule);
    function observeTimeline(timeline) {
        if (timeline !== observedTimeline) {
            timelineObserver.disconnect();
            observedTimeline = timeline;
            if (timeline) timelineObserver.observe(timeline,
                {attributes: true, attributeFilter: ["aria-valuenow", "aria-valuemax"]});
            schedule();
        }
    }
    function findMedia(root) {
        if (root instanceof HTMLMediaElement) watchMedia(root);
        for (const media of root.querySelectorAll?.("audio,video") || []) watchMedia(media);
        if (!isSoundCloud) return;
        const timeline = root.matches?.(".playbackTimeline__progressWrapper") ? root
            : root.querySelector?.(".playbackTimeline__progressWrapper");
        if (timeline) observeTimeline(timeline);
    }
    // No polling: discover replaced media/progress nodes and observe page title.
    const structureObserver = new MutationObserver(records => {
        if (observedTimeline && !observedTimeline.isConnected) observeTimeline(null);
        for (const record of records)
            for (const added of record.addedNodes) findMedia(added);
    });
    const titleObserver = new MutationObserver(schedule);
    function startObservers() {
        if (document.documentElement) structureObserver.observe(document.documentElement,
            {childList: true, subtree: true});
        if (document.head) titleObserver.observe(document.head,
            {childList: true, characterData: true, subtree: true});
        findMedia(document);
        schedule();
    }
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", startObservers, {once: true});
    else startObservers();
    window.addEventListener("pageshow", () => {lastSnapshot = ""; schedule();});

    function invoke(action, details = {}) {
        const callback = handlers.get(action);
        if (callback) { callback({action, ...details}); return true; }
        return false;
    }

    window.addEventListener("message", event => {
        if (event.source !== window || event.origin !== location.origin
                || event.data?.channel !== "quickshell-media-command-v1") return;
        const command = event.data.command;
        try {
            let action = command?.command;
            if (action === "Identify") {lastSnapshot = ""; schedule(); return;}
            if (action === "PlayPause") action = snapshot()?.state === "Playing" ? "Pause" : "Play";
            if (action === "Play") {
                if (!invoke("play") && activeMedia) activeMedia.play().catch(() => {});
            } else if (action === "Pause") {
                if (!invoke("pause") && activeMedia) activeMedia.pause();
            } else if (action === "Next") invoke("nexttrack");
            else if (action === "Previous") invoke("previoustrack");
            else if (action === "Seek") {
                const timeline = position();
                if (!finite(command.position) || timeline.duration === null) return;
                const target = Math.max(0, Math.min(timeline.duration, command.position));
                if (!invoke("seekto", {seekTime: target, fastSeek: false})) {
                    if (activeMedia) activeMedia.currentTime = target;
                    else if (timeline.position !== null) {
                        const delta = target - timeline.position;
                        invoke(delta >= 0 ? "seekforward" : "seekbackward", {seekOffset: Math.abs(delta)});
                    }
                }
            }
            schedule();
        } catch {
            // The site owns its commands and can reject an operation. Never fall
            // through to another tab or synthesize audio to make it look active.
        }
    });
    schedule();
})();
