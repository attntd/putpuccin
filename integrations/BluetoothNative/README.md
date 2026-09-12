# BluetoothNative

Agent BlueZ z interfejsem QML, napisany z użyciem publicznego Qt D-Bus/QML.
Budowanie: `python scripts/build-bluetooth-agent`. Wymaga qmake6, make,
kompilatora C++17 i nagłówków Qt QML/DBus. Biblioteka pozostaje w tym katalogu.
Nie używa prywatnego ABI QuickShella, poleceń powłoki ani procesu pomocniczego.

PairingAgent udostępnia start(devicePath), respond(requestId, value), cancel()
oraz stan tylko do odczytu: busy, devicePath, phase, prompt, code, entered,
requestId. finished(devicePath, error, failedPhase, paired) rozróżnia nieudane
parowanie od problemu z zaufaniem/połączeniem po utworzeniu pary.

Rejestracja KeyboardDisplay istnieje tylko w prywatnym połączeniu bieżącej
operacji. Agent nie zostaje agentem domyślnym systemu. Zakończenie, anulowanie,
destruktor i restart BlueZ zwalniają połączenie i odpowiedzi asynchroniczne.
Kod urządzenia i PIN nie są logowane ani zapisywane w plikach.

Pełny kontrakt, timeouty i testy: `../../plan/bluetooth.md`.

DeviceActions udostępnia start(operation, devicePath, value), busy,
devicePath i operation oraz finished(path, operation, error). Operacje:
rename (pusty value przywraca nazwę), forget, connect i disconnect.
Wynik pochodzi z odpowiedzi D-Bus; nie przechowuje kopii modelu urządzeń.
Timeouty i cykl życia opisano w plan/bluetooth.md. Dodanie typu wymaga
restartu qs po przebudowaniu już załadowanej biblioteki.
