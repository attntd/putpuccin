# Nawigacja klawiaturą — 2026-09-14

Na prośbę użytkownika cztery panele otwierają skróty Super+Shift:
P — zasilanie, N — powiadomienia, B — Bluetooth, Q — Szybkie menu.
Ponowne naciśnięcie zamyka panel. Integracja Lua w `config/menu-keybinds.lua`
wywołuje istniejące IPC `surfaces toggle` i `notifications toggle`.
Konfiguracja Hyprlanda pozostaje w dotfiles; instalator dostarcza plik Lua,
ale nie dopisuje automatycznie jego wczytywania. Dotychczasowe przypisanie
Super+Shift+N do DND należy usunąć. Użytkownik wybrał przełączanie DND
wyłącznie w menu, bez zastępczego skrótu.

Zakres obejmuje istniejące widoki PowerPopup, QuickSettingsPopup,
BluetoothPopup i NotificationCenter, bez nowych usług, ustawień ani procesów
w tle. H/L przenoszą fokus poziomo, J/K pionowo. Enter aktywuje kontrolkę,
Tab/Shift+Tab i strzałki zachowują obsługę Qt. W Quick Menu H/L na suwaku
zmienia wartość o 5 punktów procentowych, J/K przechodzi między wierszami.
J lub strzałka w dół na ikonie głośnika/mikrofonu otwiera wybór urządzeń.
Listy przewijają się do zaznaczonego wiersza; pozycje ukryte i wyłączone
nie przyjmują fokusu z nawigacji przestrzennej.

Mały komponent `components/KeyboardNavigation.qml` działa wyłącznie przy
zdarzeniu klawiatury i przy otwarciu. Współdzieli nawigację pól i przycisków;
listy zachowują własne modele i wirtualizację. Używa natywnych metod Slider
increase/decrease i sygnału moved, aby zachować binding do usługi.
Nie przechowuje kopii stanu radia/audio ani zaznaczenia w ustawieniach.
Domyślny fokus trafia na pierwszą dostępną kontrolkę, z czytelnym stanem
visualFocus i istniejącymi tokenami Theme. Układ i animacje pozostają wspólne.
Na życzenie użytkownika zaznaczenie korzysta z podświetlenia i cienkiej ramki
Metrics.borderWidth, bez podkreślania tekstu przycisków, trybów Caffeinate
i urządzeń audio. Ramka pojawia się przy visualFocus lub highlighted
delegata listy: aktywna opcja ma Theme.accent, neutralna Theme.text z alfa
0.55, a destrukcyjna zachowuje czerwony token. To obrys istniejącego tła;
nie zmienia rozmiaru, odstępów ani animacji kontrolki.

Tekstowe pola zachowują natywne wprowadzanie H/J/K/L. Nawigacja kierunkowa
omija edytory, aby przypadkowo nie rozpocząć pisania; Tab i kliknięcie nadal
mogą je wybrać. W centrum `/` przechodzi do wyszukiwania; Escape wychodzi
z pola, zachowując filtr, kolejny zamyka centrum. Szybkie odpowiedzi
zachowują Enter do wysłania i pierwszy Escape do porzucenia szkicu.
H/L przechodzą między kartą i jej przyciskami; J/K między powiadomieniami,
także między grupami i delegatami poza aktualnym viewportem.
Bluetooth zachowuje L/strzałkę w prawo/F2 do szczegółów urządzenia.

Destrukcyjne operacje nadal wymagają potwierdzenia. Enter na Wyloguj,
Uruchom ponownie lub Wyłącz odsłania Anuluj/Potwierdź. J przechodzi do
Anuluj, L do Potwierdź, Enter potwierdza. Escape porzuca wybór i przywraca
fokus do czynności. Istniejące kontrole busy/dostępności nadal obowiązują.
Escape w podmenu audio/Caffeinate najpierw wraca do jego przycisku.
ShortcutOverride chroni ten krok przed skrótem zamykającym całą wyspę.

BarIsland przekazuje fokus po utworzeniu panelu. Te cztery powierzchnie
używają OnDemand i istniejącego HyprlandFocusGrab również w formularzach
Bluetooth. Przełączenie na Exclusive zwalniało grab i zamykało formularz.
Otwarcie dotyczy aktywnego monitora, zamknięcie zwalnia loader i grab;
fokus wraca do aplikacji. Istniejąca polityka ukrywania paska nad fullscreen
obowiązuje nadal; centrum powiadomień pozostaje dostępną nakładką.

Walidacja: test_power_confirmation.py, test_caffeinate.py,
test_bluetooth_ui.py, test_notification_center.py i
test_notification_bell_wayland.py. Test_menu_keyboard_wayland.py sprawdza
rzeczywiste powierzchnie, przypisania skrótów, fokus, przełączenie wysp i 20 cykli
na prywatnym Hyprlandzie/D-Bus. Działania sprzętowe i uwierzytelnianie mają
atrapy; nie uruchamiamy drugiego pełnego shella, hostowego PAM ani radia.
Wtype dostarcza zdarzenia Super+Shift, H/J/K/L, Enter i Escape. Wyłącznie
kompozytor testowy ustawia resolve_binds_by_sym, aby rozpoznawać symbole
z tymczasowej mapy klawiszy wtype, której kody różnią się od klawiatury US.
Konfiguracja klawiatury hosta pozostaje bez zmian.
Obowiązują też scripts/test-static i tests/test_install.py.
Porównywalne CPU/RSS, klatki animacji i ograniczenia pomiaru:
[wyniki walidacji](../docs/keyboard-navigation.md#wyniki-walidacji--2026-09-14).

Wycofanie: kopia poprzedniej instalacji przez scripts/install --restore,
usunięcie wczytywania menu-keybinds.lua z Hyprlanda oraz przywrócenie
wcześniejszego skrótu DND. Nie zmienia to danych i ustawień użytkownika.

Sprawdzone API: Quickshell 0.3.1, Qt 6.11.2, Hyprland 0.56.2.
[Qt Keys](https://doc.qt.io/qt-6/qml-qtquick-keys.html),
[Qt Item](https://doc.qt.io/qt-6/qml-qtquick-item.html),
[HyprlandFocusGrab 0.3.1](https://quickshell.org/docs/v0.3.1/types/Quickshell.Hyprland/HyprlandFocusGrab/).
