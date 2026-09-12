-- This compositor is only the greeter's surface. No user config, plugins or binds.
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })
hl.config({
    input = { kb_layout = "pl" },
    misc = { disable_hyprland_logo = true, disable_splash_rendering = true,
        force_default_wallpaper = 0 },
    xwayland = { enabled = false },
    animations = { enabled = false },
})
hl.on("hyprland.start", function()
    hl.exec_cmd("/usr/local/libexec/quickshell-greeter/ui")
end)
