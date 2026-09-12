"use strict";
(() => {
    const port = browser.runtime.connect({name: "media-page"});
    const onState = event => {
        if (event.source !== window || event.origin !== location.origin
                || event.data?.channel !== "quickshell-media-state-v1") return;
        const state = event.data.state;
        if (state?.type === "remove") return port.postMessage({type: "remove"});
        if (state?.type !== "update") return;
        // Keep page-controlled extra fields and oversized strings out of the
        // extension process. Background and native host validate again.
        const bounded = {type: "update"};
        for (const key of ["state", "pageTitle", "title", "artist", "album", "artUrl"]) {
            if (typeof state[key] !== "string" || state[key].length > 4096) return;
            bounded[key] = state[key];
        }
        for (const key of ["duration", "position", "playbackRate"]) {
            if (state[key] !== null && (typeof state[key] !== "number" || !Number.isFinite(state[key]))) return;
            bounded[key] = state[key];
        }
        for (const key of ["canPlay", "canPause", "canNext", "canPrevious", "canSeek"])
            bounded[key] = state[key] === true;
        port.postMessage(bounded);
    };
    window.addEventListener("message", onState);
    port.onMessage.addListener(command => {
        window.postMessage({channel: "quickshell-media-command-v1", command}, location.origin);
    });
    const onHide = () => port.postMessage({type: "remove"});
    const onShow = () => {
        window.postMessage({channel: "quickshell-media-command-v1", command: {command: "Identify"}}, location.origin);
    };
    window.addEventListener("pagehide", onHide);
    window.addEventListener("pageshow", onShow);
    port.onDisconnect.addListener(() => {
        window.removeEventListener("message", onState);
        window.removeEventListener("pagehide", onHide);
        window.removeEventListener("pageshow", onShow);
    });
})();
