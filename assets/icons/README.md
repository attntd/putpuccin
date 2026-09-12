# Ikony aplikacji

`jellyfin.png` jest oryginalną ikoną Jellyfin MPV Shim, skopiowaną bez zmian
z zainstalowanego pliku
`~/.local/share/icons/hicolor/64x64/apps/com.github.iwalton3.jellyfin-mpv-shim.png`
(2026-09-07). Zawiera logo Jellyfina w rozdzielczości 64×64. Plik `.desktop`
aplikacji wskazuje nazwę ikony `com.github.iwalton3.jellyfin-mpv-shim`.

Kopia lokalna zapewnia ten sam wygląd również bez wybranego motywu ikon Qt.
`core/Icons.qml` jest centralnym odwołaniem; ContextModule pokazuje obraz
w polu `Metrics.iconMedium`, a przy braku obrazu używa `Icons.media` w tym
samym polu. Nie modyfikowano grafiki ani konfiguracji zewnętrznej aplikacji.
SHA-256: `d6b046d778d590fbf523c68bde2447e4203f7fd669de9a9cd50b039d3e17f752`.
