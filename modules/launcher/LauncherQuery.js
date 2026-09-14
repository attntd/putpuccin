.pragma library

function parse(text) {
    const match = text.match(/^:([afc!]?)(?:\s+([\s\S]*))?$/i);
    if (!match)
        return { mode: "", query: text.trim(), committed: false };
    return { mode: ({ a: "application", f: "file", c: "clipboard", "!": "command" })[match[1].toLowerCase()] || "recent",
        query: (match[2] || "").trim(), committed: /^:[afc!]?\s/i.test(text) };
}

function prefix(mode) {
    return ({ application: ":a", file: ":f", clipboard: ":c", recent: ":", command: ":!" })[mode] || "";
}

function command(text) {
    const quiet = /^-[qQ](?:\s|$)/.test(text);
    return { quiet: quiet, text: quiet ? text.slice(2).trim() : text.trim() };
}

function terminalArguments(text, shell) {
    const parsed = command(text);
    if (!parsed.text) return [];
    return ["kitty", parsed.quiet ? "--start-as=hidden" : "--hold", "-e", shell || "/bin/sh", "-lc", parsed.text];
}

function normalized(value) {
    return typeof value === "string" ? value.toLocaleLowerCase() : "";
}

function wordStartsWith(value, query) {
    return value.split(/[\s._\-/]+/).some(word => word.startsWith(query));
}

function applicationRelevance(application, query) {
    const name = normalized(application.name);
    const generic = normalized(application.genericName);
    const comment = normalized(application.comment);
    const keywords = application.keywords ? normalized(application.keywords.join(" ")) : "";
    if (name === query) return 0;
    if (name.startsWith(query)) return 1;
    if (wordStartsWith(name, query)) return 2;
    if (name.indexOf(query) >= 0) return 3;
    if (generic === query || generic.startsWith(query)) return 4;
    if (wordStartsWith(generic, query)) return 5;
    if (wordStartsWith(keywords, query)) return 6;
    if (generic.indexOf(query) >= 0 || keywords.indexOf(query) >= 0) return 7;
    if (comment.indexOf(query) >= 0) return 8;
    return 100;
}

function applicationResult(app) {
    return { kind: "application", id: app.id, title: app.name,
        subtitle: app.genericName || app.comment || "", icon: app.icon || "", application: app };
}

function fileResult(path) {
    return { kind: "file", id: path, title: path.slice(path.lastIndexOf("/") + 1), subtitle: path, icon: "" };
}

function clipboardResult(entry) {
    return { kind: "clipboard", id: entry.id, title: entry.preview, subtitle: "", icon: "", binary: entry.binary };
}

function results(mode, text, applications, files, clipboard, history) {
    const query = normalized(text);
    if (mode === "command") {
        const parsed = command(text);
        return parsed.text ? [{ kind: "command", id: text, title: parsed.text,
            subtitle: "", icon: "", quiet: parsed.quiet }] : [];
    }
    if (!mode && !query) return [];
    const apps = applications.filter(app => app && !app.noDisplay);
    if (mode === "recent" || (!query && (mode === "application" || mode === "file"))) {
        const byId = new Map(apps.map(app => [app.id, app]));
        const clips = new Map(clipboard.map(entry => [entry.id, entry]));
        return history.filter(record => mode === "recent" || record.kind === mode).map(record => {
            if (record.kind === "application") {
                const app = byId.get(record.id);
                return app ? applicationResult(app) : null;
            }
            if (record.kind === "file") return fileResult(record.id);
            if (record.kind === "command") {
                const parsed = command(record.id);
                return { kind: "command", id: record.id, title: parsed.text, subtitle: "", icon: "", quiet: parsed.quiet };
            }
            const entry = clips.get(record.id);
            return entry ? clipboardResult(entry) : null;
        }).filter(result => result && (!query || (result.kind === "application"
            ? applicationRelevance(result.application, query) < 100
            : normalized(result.title + " " + result.subtitle).indexOf(query) >= 0)));
    }
    let matches = [];
    if (!mode || mode === "application") {
        const ranked = apps.filter(app => applicationRelevance(app, query) < 100);
        ranked.sort((a, b) => applicationRelevance(a, query) - applicationRelevance(b, query)
            || a.name.localeCompare(b.name));
        matches = ranked.map(applicationResult);
    }
    if (!mode || mode === "file") matches = matches.concat(files.map(fileResult));
    if (!mode || mode === "clipboard") matches = matches.concat(clipboard.filter(entry =>
        normalized(entry.preview).indexOf(query) >= 0).map(clipboardResult));
    return matches;
}
