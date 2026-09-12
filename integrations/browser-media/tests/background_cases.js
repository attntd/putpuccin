return (() => {
    const event = () => ({listeners: [], addListener(f) {this.listeners.push(f);},
        emit(message) {for (const f of this.listeners) f(message);}});
    const hosts = [];
    const browser = {runtime: {onConnect: event(), connectNative() {
        const host = {onMessage: event(), onDisconnect: event(), messages: [], closed: false,
            postMessage(message) {this.messages.push(message);},
            disconnect() {this.closed = true; this.onDisconnect.emit();}};
        hosts.push(host); return host;
    }}};
    // BACKGROUND
    const check = (test, reason) => {if (!test) throw new Error(reason);};
    const port = (id, url = 'https://soundcloud.com/fixture') => ({name: 'media-page',
        sender: {frameId: 0, tab: {id}, url}, onMessage: event(), onDisconnect: event(),
        disconnected: false, postMessage() {}, disconnect() {this.disconnected = true;}});
    const update = {type: 'update', sourceHost: 'evil.example', state: 'Playing',
        pageTitle: 'Fixture page', title: 'Fixture track', artist: '', album: '', artUrl: '',
        duration: 60, position: 2, playbackRate: 1};
    const old = port(1), idle = port(2);
    browser.runtime.onConnect.emit(old); browser.runtime.onConnect.emit(idle);
    old.onMessage.emit(update);
    check(hosts.length === 1 && hosts[0].messages.length === 1, 'Duplicate initial update');
    check(hosts[0].messages[0].sourceHost === 'soundcloud.com', 'Page spoofed sourceHost');
    old.onMessage.emit({type: 'remove'});
    check(hosts[0].closed, 'Idle authorized tab kept empty host alive');
    old.onMessage.emit(update);
    check(hosts.length === 2 && !hosts[1].closed, 'Event-driven host reconnect failed');
    const replacement = port(1);
    browser.runtime.onConnect.emit(replacement);
    check(old.disconnected && hosts[1].closed, 'Replacement left old source alive');
    check(hosts[1].messages.at(-1).type === 'remove', 'Replacement did not remove old source');
    replacement.onMessage.emit(update);
    const current = hosts.at(-1), messages = current.messages.length;
    old.onDisconnect.emit(); // Delayed callback must never remove replacement.
    check(!current.closed && current.messages.length === messages, 'Old disconnect removed new source');
    const rejected = port(3, 'https://example.com/fixture');
    browser.runtime.onConnect.emit(rejected);
    check(rejected.disconnected, 'Unexpected source origin accepted');
    replacement.onDisconnect.emit();
    check(current.closed, 'Last source disconnect kept empty host alive');
    return {deferredDisconnect: true, idleTabHostCleanup: true, sourceOriginValidation: true};
})();
