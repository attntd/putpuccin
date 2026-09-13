# Powiadomienia i szybkie odpowiedzi

Kliknięcie powiadomienia z natywną akcją `inline-reply` rozwija jego pełną treść
i pole odpowiedzi z przyciskami **Wyślij** i **Anuluj**, zarówno w toaście,
jak i w centrum. Enter wysyła, Escape anuluje odpowiedź. Kolejny Escape zamyka
centrum. Przycisk **Otwórz** zachowuje dostęp do akcji domyślnej aplikacji.
Powiadomienia bez akcji odpowiedzi zachowują dotychczasowe zachowanie.

Nadejście toasta nie zabiera fokusu. Kliknięcie odpowiedzi tymczasowo przyznaje
mu klawiaturę; anulowanie, wysłanie, DND i usunięcie toasta zwalniają fokus.
Czas znikania pozostaje wstrzymany podczas pisania, również poza obszarem
karty. Anulowanie czyści szkic, zwija kartę i wznawia pozostały czas.
Długa treść przewija widok tak, aby pole i przyciski mieściły się na ekranie.

`NotificationService` ogłasza `inline-reply`, udostępnia `hasInlineReply`
i `inlineReplyPlaceholder` w żywej migawce oraz komendę `reply(uid, text)`.
Komenda odrzuca puste odpowiedzi, ponad 32768 znaków oraz nieaktualne lub
nieobsługiwane powiadomienia. Wywołuje natywne `Notification.sendInlineReply`,
bez aktywowania okna, powłoki, schowka czy osobnego klienta komunikatora.
Powodzenie oznacza przekazanie odpowiedzi do protokołu powiadomień; protokół
nie potwierdza dostarczenia wiadomości odbiorcy.

Każda powierzchnia przechowuje jeden chwilowy `NotificationReplyState`.
Szkic przetrwa odtworzenie delegatów po nadejściu lub aktualizacji powiadomienia.
Zmiana wybranego wpisu, ukrycie go przez filtr/grupę i zamknięcie powierzchni
czyszczą szkic. Pole tworzy Loader dopiero po kliknięciu, a usuwa po zakończeniu
zwijania. Szkic, treść wysłanej odpowiedzi i metadane akcji nie są zapisywane
w historii ani przenoszone przez przeładowanie QML. Po restarcie procesu stare
wpisy nie umożliwiają odpowiedzi.

## Zgodność aplikacji

Signal Desktop **8.27.0 na Linuksie nie udostępnia inline reply**. Jego
powiadomienie ma obsługę kliknięcia otwierającego rozmowę, bez przekazywania
odpowiedzi. Zgodnie z wyborem użytkownika z 2026-09-13 shell nie dodaje osobnej
integracji Signala: formularz pojawi się, gdy aplikacja udostępni natywną akcję.
Sprawdzono również kod zainstalowanego pakietu w `app.asar`.

API: [Quickshell 0.3.1 Notification](https://quickshell.org/docs/v0.3.1/types/Quickshell.Services.Notifications/Notification/).
Źródło aplikacji: [Signal Desktop — notifications.preload.ts](https://github.com/signalapp/Signal-Desktop/blob/v8.27.0/ts/services/notifications.preload.ts).

Quickshell 0.3.1 ma ograniczenie przy zastępowaniu powiadomień: natywne
`hasInlineReply` nie jest zerowane, gdy nowy zestaw akcji pomija odpowiedź,
a powtórzona akcja generuje ostrzeżenie o duplikacie. Shell korzysta z natywnej
informacji o dostępności; zamknięcie powiadomienia zawsze ją unieważnia.
Poprawa wycofywania tej akcji podczas zastępowania wymaga poprawki Quickshella.

## Sprawdzanie

```sh
scripts/test-static
python3 tests/test_install.py
QML_IMPORT_PATH="$PWD/integrations" python3 tests/test_notifications.py
QML_IMPORT_PATH="$PWD/integrations" python3 tests/test_notification_card.py
python3 tests/test_notification_center.py
python3 tests/test_notification_bell_wayland.py
```

Test protokołu korzysta z prywatnego D-Bus i sztucznych nadawców. Sprawdza
sygnał odpowiedzi, Unicode, puste/stare akcje, resident, przeładowanie i brak
treści odpowiedzi na dysku. Test Waylanda tworzy osobny kompozytor, magistralę
i katalogi. Sprawdza natywne kliknięcia i pisanie, fokus, przyciski, Enter/Escape,
20 cykli otwierania i anulowania, odtwarzanie delegatów, pauzę timeoutu,
DND oraz odpowiedź w centrum. Nie uruchamia PAM ani nie wysyła wiadomości
do innych osób. Zrzuty i pomiary pozostają w katalogu tymczasowym testu.

### Wynik walidacji — 2026-09-13

Quickshell 0.3.1, Qt 6.11.2, Hyprland 0.56.2; prywatne wyjście 1280×720/1.
Zaliczono test statyczny, 19 testów instalatora, protokół powiadomień,
20 cykli kart i centrum oraz 20 natywnych cykli odpowiedzi. Po ostatniej
poprawce pomiaru pełnego tekstu powtórzono regresje kart i centrum oraz
pełną serię natywną. Długie wiadomości nie generują pętli bindingów:
ich wysokość pochodzi z gotowego Loadera z jawną szerokością tekstu.

Porównanie tego samego testu z bazowym commitem `1df5145`; RSS w KiB, CPU
w procentach jednego rdzenia, próbka 1 s. Pierwsza próbka obejmuje rozgrzewanie
QML; po cyklach powierzchnie są zamknięte.

| Stan | CPU przed zmianą | RSS przed zmianą | CPU po zmianie | RSS po zmianie |
| --- | ---: | ---: | ---: | ---: |
| Początek | 0,00% | 205432 | 1,00% | 204996 |
| Po 20 cyklach zwykłego centrum | 0,00% | 217588 | 0,00% | 217052 |
| Po dodatkowych 20 odpowiedziach i długiej treści | — | — | 0,00% | 223988 |

RSS po zamknięciu formularza w 20 cyklach: 226148 → 223380 KiB, zakres
223124–226148 KiB; bez narastania. Dodatkowy scenariusz obejmuje edytor,
tekst Unicode, zamykanie przez nadawcę i pełny układ długiej wiadomości.
Sprawdzono zwykły i ograniczony ruch, fokus oraz dostępność przycisków przy
przewijaniu. Poza opisanym ostrzeżeniem upstream przy zastępowaniu akcji
brak ostrzeżeń QML. Geometria i okna pulpitu hosta pozostały niezmienione.

Instalacja sprawdzonej wersji: `scripts/install`. Wycofanie:
`scripts/install --restore /ścieżka/do/kopii/quickshell`. Ustawienia użytkownika
pozostają poza zmianą.
