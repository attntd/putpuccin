-- Load once from Hyprland, passing hl.bind or a registry's bind function.
-- The optional IPC prefix is used by isolated integration tests.
return function(bind, ipc)
    ipc = ipc or "qs ipc call"
    local menus = {
        {"P", "surfaces toggle power", "Menu zasilania"},
        {"N", "notifications toggle", "Powiadomienia"},
        {"B", "surfaces toggle bluetooth", "Bluetooth"},
        {"Q", "surfaces toggle quickSettings", "Szybkie menu"},
    }
    for _, menu in ipairs(menus) do
        bind("SUPER + SHIFT + " .. menu[1], hl.dsp.exec_cmd(ipc .. " " .. menu[2]),
            {description = "[QuickShell] " .. menu[3]})
    end
end
