"use strict";

// Tab identity comes exclusively from Firefox's sender, never from page data.
const allowedHosts = new Set(["soundcloud.com", "www.soundcloud.com", "music.apple.com"]);
const pages = new Map();
let nativePort = null;

function maybeCloseNative() {
    if (!nativePort || [...pages.values()].some(page => page.state)) return;
    const closing = nativePort;
    nativePort = null;
    closing.disconnect();
}

function normalize(message, sourceHost) {
    if (message?.type !== "update" || !["Playing", "Paused", "Stopped"].includes(message.state)) return null;
    const state = {type: "update", sourceHost, state: message.state};
    for (const key of ["pageTitle", "title", "artist", "album", "artUrl"]) {
        if (typeof message[key] !== "string" || message[key].length > 4096) return null;
        state[key] = message[key].slice(0, key === "artUrl" ? 4096 : 1024);
    }
    for (const key of ["duration", "position", "playbackRate"]) {
        const value = message[key];
        if (value !== null && (typeof value !== "number" || !Number.isFinite(value))) return null;
        state[key] = value;
    }
    for (const key of ["canPlay", "canPause", "canNext", "canPrevious", "canSeek"])
        state[key] = message[key] === true;
    return state;
}

function connectHost() {
    if (nativePort) return nativePort;
    const port = browser.runtime.connectNative("org.quickshell.browser_media");
    nativePort = port;
    port.onMessage.addListener(message => {
        if (message?.type !== "command") return;
        pages.get(message.tabId)?.port.postMessage(message);
    });
    port.onDisconnect.addListener(() => {
        if (nativePort === port) nativePort = null;
        // A missing host is retried on the next page event, without a timer.
        void port.error;
    });
    for (const [tabId, page] of pages) {
        if (page.state) port.postMessage({...page.state, tabId});
    }
    return port;
}

browser.runtime.onConnect.addListener(port => {
    const sender = port.sender;
    let url;
    try { url = new URL(sender?.url); } catch { return port.disconnect(); }
    if (port.name !== "media-page" || sender.frameId !== 0 || !Number.isInteger(sender.tab?.id)
            || url.protocol !== "https:" || !allowedHosts.has(url.hostname)) {
        return port.disconnect();
    }
    const tabId = sender.tab.id;
    const previous = pages.get(tabId);
    if (previous) {
        // Disconnect callbacks may run after the replacement connects. Remove
        // the old document now, including when the new page has no player.
        nativePort?.postMessage({type: "remove", tabId});
        previous.state = null;
        maybeCloseNative();
        previous.port.disconnect();
    }
    const page = {port, state: null};
    pages.set(tabId, page);
    port.onMessage.addListener(message => {
        if (pages.get(tabId) !== page) return;
        if (message?.type === "remove") {
            page.state = null;
            nativePort?.postMessage({type: "remove", tabId});
            maybeCloseNative();
            return;
        }
        const state = normalize(message, url.hostname);
        if (!state) return;
        page.state = state;
        if (nativePort) nativePort.postMessage({...state, tabId});
        else connectHost(); // New hosts receive all current snapshots once.
    });
    port.onDisconnect.addListener(() => {
        if (pages.get(tabId) !== page) return;
        pages.delete(tabId);
        nativePort?.postMessage({type: "remove", tabId});
        maybeCloseNative();
    });
});
