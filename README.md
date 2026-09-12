# Putpuccin shell

Instalacja:
```sh
./scripts/install
```

Skrypt sprawdza zależności i instaluje je przez `sudo pacman -S --needed`. Flagi opcjonalne `--dry-run` i `--skip-packages` pokazują plan bez zmiany niczego i pomijają instalację pakietów.

## Ustawienia i IPC

Shell obserwuje na żywo plik `${XDG_CONFIG_HOME:-$HOME/.config}/quickshell-de/settings.json`. Punktem startowym jest [config/settings.example.json](config/settings.example.json).

Stabilne akcje IPC:

```sh
qs ipc -p "$PWD" call surfaces toggle clipboard
qs ipc -p "$PWD" call surfaces open power
qs ipc -p "$PWD" call surfaces closeAll
qs ipc -p "$PWD" call bar setVisible false
qs ipc -p "$PWD" call clipboard setPaused true
qs ipc -p "$PWD" call screenshot open
```

Identyfikatory powierzchni: `power`, `clipboard`, `media`, `tray`, `audio`, `brightness`, `network`, `bluetooth`, `battery`, `calendar`. Powierzchnia `battery` łączy stan baterii, pozostały czas pracy i wybór profilu zasilania.
