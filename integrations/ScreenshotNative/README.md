# ScreenshotNative

Mała integracja C++ z publicznym Qt 6.11, bez API prywatnego Qt/Quickshell.
Budowanie: `python scripts/build-screenshot-exporter` z katalogu projektu.
Wymaga qmake6, make, g++ oraz nagłówków Qt Quick i Concurrent. Biblioteka
pozostaje lokalna. Po aktualizacji wymagającej przebudowania Qt lub
przeniesieniu konfiguracji zbuduj ponownie i uruchom ponownie shell.

Usługa jest jedynym właścicielem sesji i oryginalnych ItemGrabResult.
ImageExporter bierze współdzieloną kopię QImage i przycina/koduje ją w tle;
nie wywołuje QML ani nie odczytuje ekranu w wątku roboczym. Eksport nie
przelicza DPR. Wątek pisze jedynie do prywatnego, zweryfikowanego katalogu
zrzutu stworzonego przez screenshot-action i zachowuje jego blokadę `.session`.
Nie nadpisuje plików użytkownika: atomowo zastępuje tylko roboczy result.png.

Writer ma deadline 10 s i sprawdza znacznik anulowania przy zapisie.
Anulowanie/reload odłącza callback i zwalnia źródło QML; własna referencja
wątku żyje do końca pracy. Helper cleanup czeka na tę samą blokadę, więc nie
usuwa katalogu spod aktywnego kodera. Numer generacji odrzuca spóźniony wynik.
Po ukończeniu zwalniane są referencje obrazu i watcher; brak timera/pollingu.

Publiczne API:
- hasEditor(): sprawdzenie programu satty bez procesu powłoki;
- write(grab, directory, x, y, width, height, token): jeden eksport naraz;
- cancel(): żądanie anulowania, bez blokowania wątku GUI;
- busy i finished(token, ok, cancelled): zdarzeniowe zakończenie.

Źródła: [ItemGrabResult](https://doc.qt.io/qt-6/qquickitemgrabresult.html),
[QtConcurrent](https://doc.qt.io/qt-6/qtconcurrentrun.html),
[QImageWriter](https://doc.qt.io/qt-6/qimagewriter.html).
