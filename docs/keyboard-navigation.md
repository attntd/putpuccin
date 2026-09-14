# Sterowanie menu klawiaturą

| Skrót | Menu |
| --- | --- |
| Super+Shift+P | Zasilanie |
| Super+Shift+N | Powiadomienia |
| Super+Shift+B | Bluetooth |
| Super+Shift+Q | Szybkie menu |

Ponowne naciśnięcie skrótu zamyka menu. **H/L** wybiera lewo/prawo,
**J/K** góra/dół, **Enter** aktywuje, a **Escape** cofa podmenu lub zamyka
panel. Strzałki i Tab/Shift+Tab nadal działają. Wyłączone kontrolki są pomijane.
Zaznaczona pozycja ma podświetlenie i cienką ramkę: aktywna w kolorze akcentu,
nieaktywna w pasującym neutralnym kolorze. Tekst nie ma podkreślenia.

- Na suwakach H/L zmienia wartość o 5 punktów procentowych.
- J na ikonie głośnika lub mikrofonu otwiera wybór urządzeń audio.
- L na zapisanym urządzeniu Bluetooth otwiera jego szczegóły.
- W powiadomieniach J/K przechodzi między wpisami, H/L między kartą i jej
  przyciskami, a `/` otwiera wyszukiwanie. Escape wychodzi z wyszukiwania,
  zachowując filtr; kolejny zamyka centrum.
- Pola tekstowe przyjmują H/J/K/L jako zwykły tekst. Enter i Escape w odpowiedzi
  na powiadomienie zachowują wysyłanie i anulowanie.
- Wylogowanie, restart i wyłączenie wymagają potwierdzenia: Enter odsłania
  przyciski, J wybiera Anuluj, L wybiera Potwierdź, Enter wykonuje czynność.

„Nie przeszkadzać” przełącza się w menu; nie ma osobnego skrótu.

## Włączenie skrótów

Po wdrożeniu źródeł przez `scripts/install` wczytaj dostarczoną integrację
raz w konfiguracji Lua Hyprlanda:

```lua
local qs_config = os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")
dofile(qs_config .. "/quickshell/config/menu-keybinds.lua")(hl.bind)
```

Jeśli dotfiles używają rejestru skrótów, przekaż `bindings.bind` zamiast
`hl.bind`. Usuń wcześniejsze przypisanie Super+Shift+N do DND.
Instalator zachowuje kopię poprzedniej wersji i nie modyfikuje samodzielnie
Hyprlanda ani ustawień użytkownika.

## Testy

```sh
scripts/test-static
python3 tests/test_install.py
python3 tests/test_power_confirmation.py
python3 tests/test_caffeinate.py
python3 tests/test_bluetooth_ui.py
python3 tests/test_notification_center.py
python3 tests/test_menu_keyboard_wayland.py
python3 tests/test_notification_bell_wayland.py
```

Testy mają własne katalogi runtime i połączenia D-Bus. Próby Waylanda tworzą
prywatny kompozytor z atrapami uwierzytelniania i działań sprzętowych.
Test skrótów używa wtype oraz `resolve_binds_by_sym` wyłącznie w swoim
kompozytorze. Sprawdza też powrót fokusu do testowej aplikacji i zwolnienie
paneli przez 20 cykli. Nie wykonuje rzeczywistych akcji zasilania.

Kontrakt implementacji: [plan nawigacji](../plan/keyboard_navigation.md).

## Wyniki walidacji — 2026-09-14

Kontrola statyczna, 19 testów instalatora oraz regresje zasilania, Bluetooth,
Caffeinate/audio i centrum powiadomień przeszły. Test natywnego centrum
potwierdził także edycję, wysyłanie i anulowanie odpowiedzi. Test czterech
skrótów zaliczył 20 cykli, przywracanie fokusu i zwalnianie paneli, również
z ograniczeniem ruchu. Brak nowych ostrzeżeń QML.

Quickshell 0.3.1, Qt 6.11.2, Hyprland 0.56.2; ten sam prywatny kompozytor
1280 × 900 i atrapy usług przed oraz po zmianie. CPU to próbki 1 s,
procent jednego rdzenia; pierwsza próbka obejmuje jeszcze rozruch.

| Wersja | RSS przed → po 20 cyklach (KiB) | CPU przed → po |
| --- | ---: | ---: |
| Poprzednia | 215052 → 224728 | 1% → 0% |
| Z nawigacją | 214836 → 223644 | 3% → 1% |

W poprawionej wersji RSS ostatnich 10 cykli mieści się w 223088–223508 KiB,
bez narastania. Próba po zmianie obejmuje dodatkowo nawigację i aktywację
kontrolek. Nie dodano okresowych procesów, timerów ani animacji.

Osobna para prób rejestruje `frameSwapped` podczas otwierania wszystkich
czterech paneli. Mediany odstępów wyniosły 16–17 ms przed zmianą i 17 ms po;
maksimum 24 ms przed i 38 ms po (pierwsze otwarcie zasilania). Pozostałe menu
po zmianie miały maksimum 17–18 ms. Pojedyncza dłuższa klatka przy pierwszym
otwarciu wymaga ostrożnej interpretacji; krótka próba nie jest benchmarkiem
płynności całego pulpitu. Z ograniczeniem ruchu panele również otwierają się
i zwalniają prawidłowo. Testy zachowały stan monitorów i okien nadrzędnego
kompozytora. Nie sprawdzają fizycznej klawiatury, radia, audio ani zasilania.

Po usunięciu podkreśleń ponownie zaliczono regresję audio i nawigacji z 20
cyklami panelu. Podświetlenie wiersza urządzenia korzysta z natywnego
`Button.highlighted`. W izolowanym Qt offscreen CPU wyniosło 0% przed i po,
RSS 110188 → 110372 KiB; próbki przejścia zawierały klatki pośrednie
i monotonicznie osiągnęły stan otwarty.

## Cienka ramka fokusu — 2026-09-14

Ramka ma 1 px i używa istniejącego tła przycisku, bez zmiany jego rozmiaru.
Aktywne Wi-Fi ma ramkę w kolorze akcentu; nieaktywne „Nie przeszkadzać”
neutralną. Ramka przesuwa się z fokusem, a tło nadal wskazuje stan opcji.
Sprawdzono oba warianty na obrazach syntetycznego Quick menu.

Ponowna kontrola statyczna, 19 testów instalatora i po 20 cykli natywnej
nawigacji przed oraz po zmianie przeszły. Zakończenie paneli przywraca fokus
aplikacji, z normalnymi animacjami i ograniczeniem ruchu, bez ostrzeżeń QML.

| Wersja | RSS przed → po 20 cyklach (KiB) | CPU przed → po |
| --- | ---: | ---: |
| Bez ramki | 214760 → 223000 | 3% → 0% |
| Z ramką | 214988 → 224036 | 2% → 0% |

Mediana odstępu klatek podczas otwierania wyniosła 17 ms w obu wersjach,
maksimum 19 ms przed i 18 ms po. Końcowa różnica RSS wynosi około 1 MiB;
próba po zmianie zapisuje dodatkowo dwa obrazy przez Qt. Ostatnie 10 cykli
tej próby mieści się w 223524–224100 KiB, bez narastania. Obowiązują te same
ograniczenia krótkiego pomiaru na prywatnym Waylandzie co wyżej.

## Wycofanie

Przywróć kopię instalacji przez `scripts/install --restore ŚCIEŻKA_KOPII`,
usuń wczytywanie `menu-keybinds.lua` z Hyprlanda i przeładuj jego konfigurację.
