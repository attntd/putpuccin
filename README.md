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

Identyfikatory powierzchni: `power`, `clipboard`, `media`, `tray`, `quickSettings`, `audio`, `brightness`, `network`, `bluetooth`, `battery`, `calendar`. Powierzchnia `battery` łączy stan baterii, pozostały czas pracy i wybór profilu zasilania.

Quick menu ma suwaki głośnika, mikrofonu i jasności. Przytrzymanie lewego
przycisku myszy na ikonie głośnika lub mikrofonu przez sekundę rozwija listę
urządzeń pod odpowiednim suwakiem. Krótkie kliknięcie ikony wycisza dany tor,
a suwak reguluje poziom bez tooltipa na hover. Z klawiatury listę otwiera ↓
na ikonie; strzałki i Enter/Spacja wybierają urządzenie. Escape zamyka listę
i przywraca fokus ikonie.
Regresja gestów i cyklu życia: `QS_QUICK_AUDIO_ONLY=1 python3 tests/test_caffeinate.py`
(prywatny D-Bus, atrapy urządzeń).

Klawisz zmniejszania jasności najpierw dochodzi do 1%, a kolejne naciśnięcie
ustawia sprzętowe 0. Zwiększanie z 0% przywraca 1%. Suwaki zachowują zakres
1–100%; IPC `brightness set 0` również zeruje podświetlenie.
Regresja bez zmieniania jasności pulpitu: `python3 tests/test_brightness_service.py`
oraz `python3 tests/test_brightness_transition.py`.

Powiadomienia obsługują [natywne szybkie odpowiedzi](modules/notifications/README.md)
z polem wiadomości i przyciskami Wyślij/Anuluj, gdy aplikacja udostępnia akcję
`inline-reply`. Signal Desktop 8.27.0 na Linuksie jeszcze jej nie udostępnia.
