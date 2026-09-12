# Quickshell Browser Media

Przygotowana lokalna integracja SoundCloud i Apple Music dla Zen. Działa
zdarzeniowo: rzeczywisty odtwarzacz strony → rozszerzenie → native messaging →
MPRIS → istniejący panel multimediów. Nie generuje pomocniczego audio.

**Status:** kod i host są przygotowane, test pełnej ścieżki przeszedł w osobnym
profilu Zen 1.21.16b / Gecko 154.0.1. Dodatek nie jest wczytany do używanego
profilu. Nie sprawdzono jeszcze odtwarzania w zalogowanych kartach użytkownika.
Tymczasowy dodatek znika po zamknięciu przeglądarki; trwała instalacja wymaga
podpisu Mozilla. Nie zmieniano weryfikacji podpisów ani konfiguracji używanego
profilu. Niczego nie wysłano do AMO.

## Włączenie teraz

1. W Zen otwórz `about:debugging#/runtime/this-firefox`.
2. Kliknij **Wczytaj tymczasowy dodatek / Load Temporary Add-on** i wskaż:
   `~/.config/quickshell/integrations/browser-media/extension/manifest.json`.
3. Odśwież tylko otwarte karty SoundCloud i Apple Music. Obserwatory muszą działać
   od początku dokumentu, zanim strona rejestruje Media Session. Następnie sam
   wznów odtwarzanie; odświeżenie strony może je zatrzymać.
4. W panelu multimediów sprawdź tytuł strony ponad okładką, tytuł materiału,
   bieżącą pozycję i długość. Sprawdź pauzę/wznowienie oraz przewinięcie, jeśli
   strona udostępnia taką operację. Przejdź do innej karty: źródło powinno nadal
   opisywać tę samą stronę odtwarzania.

Manifest z lokalną ścieżką generuje `scripts/install` w instalowanej kopii.
W bieżącym środowisku native host jest już zarejestrowany w
`~/.mozilla/native-messaging-hosts/org.quickshell.browser_media.json`.
Ten plik sam niczego nie uruchamia. Host startuje dopiero po danych z dodatku,
a kończy po usunięciu ostatniego źródła lub zamknięciu portu dodatku. Nie trzeba
restartować Zen ani Quickshell.

Tymczasowe wczytanie jest oficjalną ścieżką testową Mozilla i nie pokazuje
zwykłego kompletu dialogów instalacyjnych. Konkretne uprawnienia poniżej należy
przeczytać przed wczytaniem. Po przyszłym podpisaniu XPI normalna instalacja
będzie wymagać zatwierdzenia dodatku i jego uprawnień w przeglądarce.
[Dokumentacja wczytania tymczasowego](https://extensionworkshop.com/documentation/develop/temporary-installation-in-firefox/).

## Wycofanie

1. Na tej samej stronie `about:debugging` kliknij **Usuń / Remove** przy
   **Quickshell Browser Media**. Port się zamknie, a źródła bridge znikną.
2. Odśwież karty SoundCloud i Apple Music, aby usunąć również obserwatory
   z kontekstu JavaScript stron. Nie trzeba zamykać pozostałych kart.
3. Aby usunąć także nieaktywną rejestrację hosta, usuń wyłącznie
   `~/.mozilla/native-messaging-hosts/org.quickshell.browser_media.json`.
   Kod w tym katalogu może pozostać do przeglądu.

Natywne MPRIS Zen pozostaje włączone przez cały czas. Panel ukrywa duplikat
wyłącznie przy jednoznacznym dopasowaniu źródła/tytułu/artysty/albumu; ręczny
wybór odtwarzacza pozostaje nadrzędny. Szczegóły w [docs/media.md](../../docs/media.md).

## Zakres dostępu i dane

Manifest zawiera jedynie `nativeMessaging` oraz te trzy zakresy HTTPS:

- `https://soundcloud.com/*`
- `https://www.soundcloud.com/*`
- `https://music.apple.com/*`

Nie ma uprawnień `tabs`, `history`, `cookies`, `webRequest`, `downloads`,
`storage` ani dostępu do wszystkich witryn. Skrypty działają tylko w głównym
dokumencie wskazanych witryn; iframe nie jest źródłem. Kontekst MAIN obserwuje
standardowe API strony. Osobny kontekst rozszerzenia przekazuje ograniczony
schemat danych do background; źródło i tabId pochodzą z zaufanego sendera
przeglądarki, a nie z komunikatu strony. Host akceptuje tylko ID dodatku
`quickshell-browser-media@local`.

Przesyłane lokalnie: stan odtwarzania, tytuł utworu i strony tego samego
dokumentu, artysta, album, prawdziwa długość/pozycja/tempo, dostępne sterowanie,
publiczny adres okładki oraz techniczny identyfikator karty. Dane trafiają do
sesyjnego D-Bus tak jak zwykłe MPRIS i są dostępne aplikacjom tej samej sesji.
Host przechowuje je wyłącznie w pamięci. Brak telemetryki, logowania mediów,
czytania kont, tokenów, historii, cookies i adresów strumieni. Host i dodatek
nie wykonują żądań sieciowych. Panel może pobierać okładkę z `mzstatic.com` lub
`sndcdn.com` oraz ich subdomen; host odrzuca inne hosty i usuwa z adresu query,
fragment oraz adresy z danymi logowania.

Dane strony są niezaufane: relay ogranicza pola i długości przed wysłaniem,
background ponownie waliduje schemat/pochodzenie, a host waliduje liczby,
hosty i ramki native messaging (maksymalnie 256 KiB). Sterowanie ma zamkniętą
listę Play, Pause, PlayPause, Next, Previous i Seek i trafia wyłącznie do karty
źródła. Nie ma powłoki, wykonywania poleceń dostarczanych przez stronę,
zewnętrznego pollera, sztucznego odtwarzania ani globalnego wyłączenia MPRIS.

## Skąd bierze się czas

HTMLMediaElement: `duration/currentTime/playbackRate`, aktualizowane zdarzeniami
play/playing/pause/timeupdate/durationchange/seeked/ratechange. Obserwowane są
również prawdziwe elementy audio przechowywane poza DOM.

WebAudio: obserwacja publicznego `MediaSession.setPositionState`, ustawiania
metadata/playbackState i zarejestrowanych przez stronę action handlers.
Pauza rozlicza czas od poprzedniej pozycji, a wznowienie nie cofa osi.

SoundCloud dodatkowo udostępnia rzeczywisty postęp w atrybutach dostępności
`.playbackTimeline__progressWrapper`. **Obie wartości są w sekundach**:
publiczny kod `playbackTimeline` dzieli czas modelu przez 1000 i zaokrągla w dół
przed ustawieniem aria-valuemax/aria-valuenow. Obserwacja samych atrybutów
nie wymaga odpytywania wewnętrznego odtwarzacza ani sieci. Brak atrybutu jest
traktowany jako nieznana pozycja, a nie zero. Gdy nie ma wiarygodnej pozycji
lub długości, bridge nie publikuje zakresu ani przewijania.

MutationObserver śledzi zmianę tytułu i dodane gałęzie DOM, a nie skanuje całej
strony po każdej zmianie komentarzy. Zmiana karty/URL nie zastępuje źródła
przez dowolne aktywne okno. Zamknięcie, nawigacja i podmiana portu usuwają
źródło starego dokumentu, także przy opóźnionym disconnect. Pozostawione karty
bez odtwarzacza nie utrzymują pustego hosta.

## Testy i granice potwierdzenia

Z katalogu Quickshell:

```sh
python integrations/browser-media/tests/test_host.py
python integrations/browser-media/tests/test_browser.py
python tests/test_media.py
```

Test przeglądarki używa nowego, wyciszonego profilu, prywatnego D-Bus,
localhost HTTPS i syntetycznych stron pod nazwami dwóch dozwolonych hostów
(rozwiązywanie nazw zmienione tylko w profilu testowym). Używa niezmienionego
manifestu i oficjalnej tymczasowej instalacji przez Marionette. Potrzebne są
Zen, Python z dbus-python, dbus-run-session i OpenSSL oraz zarejestrowany host.
Nie używa istniejących kont/kart i nie zmienia podpisów. Lokalny samopodpisany
certyfikat jest akceptowany tylko w sesji testowej WebDriver.

Potwierdzono pełne MAIN → relay → nativeMessaging → rzeczywisty MPRIS:
czyste WebAudio bez pomocniczego HTML media, prawdziwe 40 s HTML audio,
Play/Pause/SetPosition, pauzę/wznowienie bez kolejnego setPositionState,
nieznaną pozycję przy brakującym ARIA, dwie niezależne karty, tytuł strony
w tle, brak starej długości po HTML audio → WebAudio oraz cleanup po
nawigacji/zamknięciu. Osobny scenariusz w tym samym silniku JS sprawdza
opóźniony disconnect, walidację sendera i zamykanie hosta przy samych idle
kartach. Test hosta sprawdza ramki, możliwości, niezależne źródła oraz EOF.

Ostatni wynik browsera: `/tmp/quickshell-browser-media-4z4aou_b/result.json`.
To potwierdza mechanizm integracji w zainstalowanym Zen. **Nie zastępuje testu
rzeczywistych stron po wczytaniu dodatku przez użytkownika**: serwisy mogą
zmieniać implementację, tryb odtwarzania i dostępne sterowanie.

## Diagnoza i trwałe wdrożenie

Mozilla potwierdza ograniczenie czystego WebAudio w integracji systemowej.
[Bug 2067534](https://bugzilla.mozilla.org/show_bug.cgi?id=2067534) opisuje
konkretnie różne ścieżki SoundCloud: HTMLMediaElement i czyste WebAudio,
pomimo poprawnego Media Session. Kod Gecko 154 wymaga aktywnego kontrolowanego
media do uruchomienia kontrolera. Odczyt sesji użytkownika podczas diagnozy
nie miał właścicieli MPRIS, więc nie identyfikuje przyczyny jego konkretnego
odtwarzania. Nie przypisujemy tego automatycznie innemu błędowi Gecko 154.

Sprawdzony dodatek AMO SoundCloud Media Controls Fix 1.0.0 został odrzucony:
odtwarza pomocniczy ton, odpytuje stronę co 500 ms i używa odrzucanego przez
Gecko playbackRate=0 w setPositionState. KDE Plasma Browser Integration ma
szersze uprawnienia i również zakłada aktywny HTMLMediaElement przy Media
Session. Żadne z nich nie domykało tej integracji dla czystego WebAudio,
osi Apple Music i osobnego tytułu strony.

Trwała instalacja wymaga podpisanego przez Mozilla XPI. Można wybrać podpis
unlisted (bez publicznego katalogu), ale nadal oznacza to przesłanie kodu do
Mozilla i odrębne zatwierdzenie tego kroku. Nie wyłączaj
`xpinstall.signatures.required`. Podpisanego pakietu obecnie nie ma.
[Zasady podpisywania i dystrybucji](https://extensionworkshop.com/documentation/publish/signing-and-distribution-overview/).

Źródła pierwotne:

- [MPRIS ServiceHandler w Gecko 154.0.1](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_154_0_1_RELEASE/widget/gtk/MPRISServiceHandler.cpp).
- [Publiczny kod SoundCloud playbackTimeline](https://a-v2.sndcdn.com/assets/0-a583ec81.js)
  i [Media Session playbackState](https://a-v2.sndcdn.com/assets/55-70f3b3d1.js).
- [Native messaging](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Native_messaging)
  i [kontekst MAIN content scripts](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/manifest.json/content_scripts).
