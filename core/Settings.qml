pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    readonly property int supportedSchemaVersion: 1
    readonly property string configHome: {
        const xdg = Quickshell.env("XDG_CONFIG_HOME");
        const home = Quickshell.env("HOME");
        return xdg && xdg.length > 0 ? xdg : (home ? home + "/.config" : "/tmp");
    }
    readonly property string path: configHome + "/quickshell-de/settings.json"

    property string errorMessage: ""
    property bool usingDefaults: true
    property int revision: 0

    property bool wallpaperEnabled: true
    property string lockAvatarPath: configHome + "/hypr/putek_mocha_avatar.png"
    property string wallpaperDirectory: ""
    property int wallpaperIntervalMinutes: 30
    property int wallpaperTransitionDuration: 3000
    property string screenshotDirectory: ""
    property bool screenshotPaintCursor: false

    property int barHeight: 40
    property int topMargin: 8
    property int sideMargin: 12
    property int reservedHeight: 48
    property bool hideOnFullscreen: true
    property bool reducedMotion: false
    property bool polkitEnabled: true
    property real barSurfaceOpacity: 0.90
    property real surfaceOpacity: 0.84
    property real interactiveOpacity: 0.0
    property real launcherPositionFromBottom: 0.65
    property int hoverCloseDelay: 180
    property int trayVisibleItems: 3
    property int volumeStep: 5
    property int brightnessStep: 5
    property bool clipboardAutoPaste: false
    property int clipboardMaxItems: 50
    property int clipboardMaxBytes: 2097152
    property bool notificationSoundEnabled: true
    property bool notificationShowBadge: false
    property int notificationToastDuration: 6000
    property int notificationMaxToasts: 3
    property int notificationHistoryDays: 7
    property int notificationHistoryLimit: 500
    property int notificationWidth: 420
    property real notificationCenterHeightFraction: 1.0
    property string clockFormat: "HH:mm"
    property string clockDateFormat: "d MMM"
    property var leftModules: ["power", "workspaces"]
    property var centerModules: ["launcher", "context", "media"]
    property var rightModules: ["tray", "clipboard", "network", "bluetooth", "battery", "notifications", "quickSettings", "clock"]
    property var moduleOptions: ({})

    readonly property var knownModules: [
        "power", "launcher", "workspaces", "context", "media", "clipboard", "tray",
        "audio", "brightness", "quickSettings", "network", "bluetooth", "battery",
        "notifications", "clock"
    ]
    readonly property var knownActions: [
        "none", "openPopup", "toggleMute", "increase", "decrease",
        "activate", "secondaryActivate", "toggleDnd", "launchFallback"
    ]

    function clampNumber(value, fallback, minimum, maximum) {
        const number = Number(value);
        return Number.isFinite(number) ? Math.max(minimum, Math.min(maximum, number)) : fallback;
    }

    function validateModules(value, zone, alreadySeen, problems) {
        const fallback = zone === "left" ? ["power", "workspaces"]
            : zone === "center" ? ["launcher", "context", "media"]
            : ["tray", "clipboard", "network", "bluetooth", "battery", "notifications", "quickSettings", "clock"];
        // JsonAdapter exposes QVariantList as a QML sequence, not always a JS Array.
        if (value && !Array.isArray(value) && typeof value === "object" && Number.isInteger(value.length))
            value = Array.from(value);
        if (!Array.isArray(value)) {
            problems.push("Strefa " + zone + " nie jest listą.");
            value = fallback;
        }

        const result = [];
        for (const id of value) {
            if (typeof id !== "string" || root.knownModules.indexOf(id) < 0) {
                problems.push("Nieznany moduł w strefie " + zone + ": " + id);
                continue;
            }
            if (alreadySeen[id]) {
                problems.push("Moduł występuje więcej niż raz: " + id);
                continue;
            }
            alreadySeen[id] = true;
            result.push(id);
        }
        return result;
    }

    function validateOptions(value, problems) {
        if (value === null || typeof value !== "object" || Array.isArray(value)) {
            problems.push("moduleOptions musi być obiektem.");
            return {};
        }

        const result = {};
        for (const moduleId in value) {
            if (root.knownModules.indexOf(moduleId) < 0) {
                problems.push("Opcje nieznanego modułu: " + moduleId);
                continue;
            }
            const options = value[moduleId];
            if (options === null || typeof options !== "object" || Array.isArray(options)) {
                problems.push("Opcje modułu " + moduleId + " muszą być obiektem.");
                continue;
            }
            const clean = {};
            const allowedKeys = ["presentation", "expandOnHover", "primaryAction", "secondaryAction", "scrollUpAction", "scrollDownAction"];
            for (const optionKey in options) {
                if (allowedKeys.indexOf(optionKey) < 0)
                    problems.push("Nieznana opcja " + moduleId + "." + optionKey);
            }
            if (typeof options.presentation === "string" && ["adaptive", "icon", "label"].indexOf(options.presentation) >= 0)
                clean.presentation = options.presentation;
            else if (options.presentation !== undefined)
                problems.push("Nieprawidłowa prezentacja modułu: " + moduleId);
            if (typeof options.expandOnHover === "boolean")
                clean.expandOnHover = options.expandOnHover;
            else if (options.expandOnHover !== undefined)
                problems.push("Nieprawidłowy typ expandOnHover: " + moduleId);
            for (const key of ["primaryAction", "secondaryAction", "scrollUpAction", "scrollDownAction"]) {
                if (options[key] === undefined)
                    continue;
                if (root.knownActions.indexOf(options[key]) >= 0)
                    clean[key] = options[key];
                else
                    problems.push("Niedozwolona akcja " + moduleId + "." + key);
            }
            result[moduleId] = clean;
        }
        return result;
    }

    function defaultConfig() {
        return {
            schemaVersion: 1,
            wallpaperEnabled: true,
            lockAvatarPath: root.configHome + "/hypr/putek_mocha_avatar.png",
            wallpaperDirectory: "",
            wallpaperIntervalMinutes: 30,
            wallpaperTransitionDuration: 3000,
            screenshotDirectory: "",
            screenshotPaintCursor: false,
            barHeight: 40,
            topMargin: 8,
            sideMargin: 12,
            reservedHeight: 48,
            hideOnFullscreen: true,
            reducedMotion: false,
            polkitEnabled: true,
            barSurfaceOpacity: 0.90,
            surfaceOpacity: 0.84,
            interactiveOpacity: 0.0,
            launcherPositionFromBottom: 0.65,
            hoverCloseDelay: 180,
            trayVisibleItems: 3,
            volumeStep: 5,
            brightnessStep: 5,
            clipboardAutoPaste: false,
            clipboardMaxItems: 50,
            clipboardMaxBytes: 2097152,
            notificationSoundEnabled: true,
            notificationShowBadge: false,
            notificationToastDuration: 6000,
            notificationMaxToasts: 3,
            notificationHistoryDays: 7,
            notificationHistoryLimit: 500,
            notificationWidth: 420,
            notificationCenterHeightFraction: 1.0,
            clockFormat: "HH:mm",
            clockDateFormat: "d MMM",
            leftModules: ["power", "workspaces"],
            centerModules: ["launcher", "context", "media"],
            rightModules: ["tray", "clipboard", "network", "bluetooth", "battery", "notifications", "quickSettings", "clock"],
            moduleOptions: ({})
        };
    }

    function validatedConfig(value) {
        if (!value || typeof value !== "object" || Array.isArray(value))
            throw new Error("Ustawienia muszą być obiektem JSON.");
        if (value.schemaVersion !== root.supportedSchemaVersion)
            throw new Error("Nieobsługiwana wersja ustawień: " + value.schemaVersion);
        const defaults = root.defaultConfig();
        const source = Object.assign({}, defaults);
        const problems = [];
        const realKeys = ["barSurfaceOpacity", "surfaceOpacity", "interactiveOpacity",
            "launcherPositionFromBottom", "notificationCenterHeightFraction"];
        for (const key of Object.keys(value)) {
            if (!Object.prototype.hasOwnProperty.call(defaults, key)) {
                problems.push("Nieznane ustawienie: " + key);
                continue;
            }
            const item = value[key];
            const expected = defaults[key];
            if (Array.isArray(expected) ? !Array.isArray(item)
                    : expected !== null && typeof expected === "object"
                        ? item === null || typeof item !== "object" || Array.isArray(item)
                        : typeof item !== typeof expected || (typeof item === "number" && !Number.isFinite(item))) {
                problems.push("Nieprawidłowy typ ustawienia: " + key);
                continue;
            }
            source[key] = item;
            if (typeof item === "number" && realKeys.indexOf(key) < 0 && !Number.isInteger(item))
                problems.push("Ustawienie wymaga liczby całkowitej: " + key);
        }
        if (!source.lockAvatarPath.startsWith("/"))
            problems.push("lockAvatarPath wymaga ścieżki absolutnej.");
        if (source.wallpaperDirectory !== "" && !source.wallpaperDirectory.startsWith("/"))
            problems.push("wallpaperDirectory wymaga ścieżki absolutnej.");
        if (source.screenshotDirectory !== "" && (!source.screenshotDirectory.startsWith("/")
                || /[\u0000-\u001f\u007f]/.test(source.screenshotDirectory)))
            problems.push("screenshotDirectory wymaga ścieżki absolutnej bez znaków sterujących albo pustej wartości.");
        if (!source.clockFormat.length || !source.clockDateFormat.length)
            problems.push("Format daty i czasu nie może być pusty.");
        const seen = {};
        for (const zone of ["left", "center", "right"])
            source[zone + "Modules"] = root.validateModules(source[zone + "Modules"], zone, seen, problems);
        source.moduleOptions = root.validateOptions(source.moduleOptions, problems);
        if (problems.length) throw new Error(problems.join("\n"));
        return source;
    }

    function loadText() {
        try {
            const source = root.validatedConfig(JSON.parse(file.text()));
            root.applyAdapter(source);
        } catch (error) {
            // Retain the last complete configuration. Before the first valid
            // load these are the actual defaults initialized above.
            root.errorMessage = error.message || String(error);
        }
    }

    function applyAdapter(source) {
        const problems = [];
        if (source.schemaVersion !== root.supportedSchemaVersion) {
            root.errorMessage = "Nieobsługiwana wersja ustawień: " + source.schemaVersion;
            return;
        }

        const seen = {};
        root.wallpaperEnabled = source.wallpaperEnabled;
        root.lockAvatarPath = typeof source.lockAvatarPath === "string" && source.lockAvatarPath.startsWith("/")
            ? source.lockAvatarPath : root.configHome + "/hypr/putek_mocha_avatar.png";
        root.wallpaperDirectory = typeof source.wallpaperDirectory === "string"
            && (source.wallpaperDirectory === "" || source.wallpaperDirectory.startsWith("/"))
            ? source.wallpaperDirectory : "";
        root.wallpaperIntervalMinutes = Math.round(root.clampNumber(source.wallpaperIntervalMinutes, 30, 1, 1440));
        root.wallpaperTransitionDuration = Math.round(root.clampNumber(source.wallpaperTransitionDuration, 3000, 0, 10000));
        root.screenshotDirectory = source.screenshotDirectory;
        root.screenshotPaintCursor = source.screenshotPaintCursor;
        root.barHeight = Math.round(root.clampNumber(source.barHeight, 40, 34, 64));
        root.topMargin = Math.round(root.clampNumber(source.topMargin, 8, 0, 32));
        root.sideMargin = Math.round(root.clampNumber(source.sideMargin, 12, 0, 64));
        root.reservedHeight = Math.round(root.clampNumber(source.reservedHeight, root.barHeight + root.topMargin, root.barHeight, 96));
        root.hideOnFullscreen = source.hideOnFullscreen;
        root.reducedMotion = source.reducedMotion;
        root.polkitEnabled = source.polkitEnabled !== false;
        root.barSurfaceOpacity = root.clampNumber(source.barSurfaceOpacity, 0.90, 0.55, 1.0);
        root.surfaceOpacity = root.clampNumber(source.surfaceOpacity, 0.84, 0.55, 1.0);
        root.interactiveOpacity = root.clampNumber(source.interactiveOpacity, 0.0, 0.0, 1.0);
        root.launcherPositionFromBottom = root.clampNumber(source.launcherPositionFromBottom,
            0.65, 0.1, 0.9);
        root.hoverCloseDelay = Math.round(root.clampNumber(source.hoverCloseDelay, 180, 0, 1000));
        root.trayVisibleItems = Math.round(root.clampNumber(source.trayVisibleItems, 3, 0, 12));
        root.volumeStep = Math.round(root.clampNumber(source.volumeStep, 5, 1, 20));
        root.brightnessStep = Math.round(root.clampNumber(source.brightnessStep, 5, 1, 20));
        root.clipboardAutoPaste = source.clipboardAutoPaste;
        root.clipboardMaxItems = Math.round(root.clampNumber(source.clipboardMaxItems, 50, 1, 500));
        root.clipboardMaxBytes = Math.round(root.clampNumber(source.clipboardMaxBytes, 2097152, 1024, 10485760));
        root.notificationSoundEnabled = source.notificationSoundEnabled === true;
        root.notificationShowBadge = source.notificationShowBadge === true;
        root.notificationToastDuration = Math.round(root.clampNumber(source.notificationToastDuration, 6000, 1000, 30000));
        root.notificationMaxToasts = Math.round(root.clampNumber(source.notificationMaxToasts, 3, 1, 5));
        root.notificationHistoryDays = Math.round(root.clampNumber(source.notificationHistoryDays, 7, 1, 30));
        root.notificationHistoryLimit = Math.round(root.clampNumber(source.notificationHistoryLimit, 500, 1, 500));
        root.notificationWidth = Math.round(root.clampNumber(source.notificationWidth, 420, 320, 640));
        root.notificationCenterHeightFraction = root.clampNumber(source.notificationCenterHeightFraction, 1.0, 0.2, 1.0);
        root.clockFormat = typeof source.clockFormat === "string" && source.clockFormat.length > 0 ? source.clockFormat : "HH:mm";
        root.clockDateFormat = typeof source.clockDateFormat === "string" && source.clockDateFormat.length > 0 ? source.clockDateFormat : "d MMM";
        // Keep Repeater delegates and their popup Components alive when an
        // unrelated setting changes, including while a popup is being loaded.
        for (const zone of ["left", "center", "right"]) {
            const key = zone + "Modules";
            const modules = root.validateModules(source[key], zone, seen, problems);
            if (JSON.stringify(root[key]) !== JSON.stringify(modules))
                root[key] = modules;
        }
        root.moduleOptions = root.validateOptions(source.moduleOptions, problems);
        root.errorMessage = problems.join("\n");
        root.usingDefaults = false;
        root.revision++;
    }

    function resetToDefaults(reason) {
        root.lockAvatarPath = root.configHome + "/hypr/putek_mocha_avatar.png";
        root.wallpaperEnabled = true;
        root.wallpaperDirectory = "";
        root.wallpaperIntervalMinutes = 30;
        root.wallpaperTransitionDuration = 3000;
        root.screenshotDirectory = "";
        root.screenshotPaintCursor = false;
        root.barHeight = 40;
        root.topMargin = 8;
        root.sideMargin = 12;
        root.reservedHeight = 48;
        root.hideOnFullscreen = true;
        root.reducedMotion = false;
        root.polkitEnabled = true;
        root.barSurfaceOpacity = 0.90;
        root.surfaceOpacity = 0.84;
        root.interactiveOpacity = 0.0;
        root.launcherPositionFromBottom = 0.65;
        root.hoverCloseDelay = 180;
        root.trayVisibleItems = 3;
        root.volumeStep = 5;
        root.brightnessStep = 5;
        root.clipboardAutoPaste = false;
        root.clipboardMaxItems = 50;
        root.clipboardMaxBytes = 2097152;
        root.notificationSoundEnabled = true;
        root.notificationShowBadge = false;
        root.notificationToastDuration = 6000;
        root.notificationMaxToasts = 3;
        root.notificationHistoryDays = 7;
        root.notificationHistoryLimit = 500;
        root.notificationWidth = 420;
        root.notificationCenterHeightFraction = 1.0;
        root.clockFormat = "HH:mm";
        root.clockDateFormat = "d MMM";
        root.leftModules = ["power", "workspaces"];
        root.centerModules = ["launcher", "context", "media"];
        root.rightModules = ["tray", "clipboard", "network", "bluetooth", "battery", "notifications", "quickSettings", "clock"];
        root.moduleOptions = {};
        root.errorMessage = reason || "";
        root.usingDefaults = true;
        root.revision++;
    }

    function option(moduleId, key, fallback) {
        root.revision;
        const options = root.moduleOptions[moduleId];
        return options && options[key] !== undefined ? options[key] : fallback;
    }

    function save() {
        const values = root.defaultConfig();
        for (const key of Object.keys(values))
            if (key !== "schemaVersion") values[key] = root[key];
        try {
            const source = root.validatedConfig(values);
            file.setText(JSON.stringify(source, null, 2) + "\n");
        } catch (error) {
            root.errorMessage = error.message || String(error);
        }
    }

    Timer {
        id: validationDebounce
        interval: 0
        onTriggered: root.loadText()
    }

    FileView {
        id: file
        path: root.path
        watchChanges: true
        printErrors: false
        atomicWrites: true
        onFileChanged: reload()
        onLoaded: validationDebounce.restart()
        onSaved: validationDebounce.restart()
        onLoadFailed: error => root.errorMessage = error.toString()
        onSaveFailed: error => root.errorMessage = error.toString()

    }
}
