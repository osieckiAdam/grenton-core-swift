# grenton-core-swift — plan portu Swift

| | |
|---|---|
| **Status** | Projekt (do implementacji) |
| **Data** | 2026-08-19 |
| **Dokument bazowy** | `grenton-core-design.md` (specyfikacja agnostyczna) — repo [grenton-core-spec](https://github.com/osieckiAdam/grenton-core-spec), submodule `vendor/grenton-core-spec` |
| **Cel** | Pakiet SPM konsumowany przez aplikacje iOS/macOS |

Ten dokument przekłada specyfikację agnostyczną na konkretne decyzje Swiftowe: strukturę pakietu, mapowanie typów, wybór frameworków (sieć, kryptografia, ZIP), model współbieżności i plan implementacji. Numeracja sekcji specyfikacji bazowej przywoływana jako „spec §…". Reguła nadrzędna: **tam, gdzie spec definiuje zachowanie, ten dokument definiuje tylko „czym" je zrealizować** — każda niezgodność zachowania to bug portu.

---

## 1. Założenia i platformy

| Decyzja | Wybór | Uzasadnienie |
|---|---|---|
| Toolchain | Swift 6.x, `swift-tools-version: 6.0` | strict concurrency wyłapuje wyścigi w sesji UDP na etapie kompilacji |
| Language mode | Swift 6 (pełna izolacja aktorów) | jw.; kod nowy, nie ma kosztu migracji |
| Platformy | iOS 16+, macOS 13+ | `Network.framework` + async/await dojrzałe; bez `@Observable` (iOS 17) w Core — patrz §5.4 |
| Zależności zewn. | tylko `ZIPFoundation`, wyłącznie w targecie Provisioning | Runtime i Model mają zero zależności — najłatwiejsze do audytu i osadzenia |
| Kryptografia | CommonCrypto (systemowe) | AES-CBC+PKCS7 natywnie; CryptoKit **nie ma** CBC. Alternatywa dla przyszłego Linuksa: `swift-crypto/_CryptoExtras` za protokołem `GrentonCipher` (§4.1) |
| Sieć UDP | dwa tryby: `NWConnection` (domyślny) i niepodłączony socket BSD (fallback, §4.3) | connected-UDP daje per-socket port efemeryczny i filtrowanie peera; socket BSD odbiera od dowolnego nadawcy — oba wymagane przez spec §7.1 |
| Testy | swift-testing (`@Test`) + fixtury z repo spec | wspólne złote wektory (spec §9) |

## 2. Struktura pakietu

```
grenton-core-swift/
├── Package.swift
├── Sources/
│   ├── GrentonModel/          // spec §3 — typy, DTO, casting; zero importów poza Foundation
│   ├── GrentonProvisioning/   // spec §4 — klient OM; deps: GrentonModel, ZIPFoundation
│   ├── GrentonRuntime/        // spec §5 — cipher, wire, sesje, StateStore; deps: GrentonModel
│   └── GrentonDevices/        // spec §6 — model kanoniczny; deps: GrentonModel, GrentonRuntime
├── Tests/
│   ├── GrentonModelTests/     // fixtury data.json, tabela castowania
│   ├── GrentonRuntimeTests/   // złote wektory AES, payloady, FakeCLU
│   ├── GrentonDevicesTests/   // mapowanie, normalizacje
│   ├── GrentonConformanceTests/ // runner zestawu zgodności z grenton-core-spec (+ port.json)
│   └── Fixtures/              // współdzielone zasoby (Bundle.module)
├── vendor/grenton-core-spec/  // submodule: specyfikacja + conformance/
└── Examples/
    └── grenton-cli/           // executable target: smoke test na żywej instalacji
```

Produkty: `GrentonCore` (umbrella: Model+Runtime+Devices), `GrentonProvisioning` (osobno — aplikacja, która dostaje konfigurację inną drogą, nie linkuje ZIPFoundation).

Wszystkie typy publiczne są `Sendable`; DTO i typy domenowe to `struct`/`enum` (wartościowe), stan mutowalny żyje wyłącznie w aktorach Runtime.

## 3. GrentonModel

### 3.1 `GrentonValue`

```swift
public enum GrentonValue: Equatable, Sendable {
    case string(String)
    case bool(Bool)
    case int(Int64)      // spec §3.1: szerokość zdefiniowana jako 64-bit, nie platformowa
    case double(Double)
    case null
}
```

Casting przewodowy (spec §3.1) jako `init(wireString:)` — ścisła gramatyka liczb przez wyrażenie regularne / ręczny skan, **nie** `Int64("…")`/`Double("…")` w ciemno: `Double` Swifta akceptuje `inf`, `nan`, heksy — spec tego zabrania. Kolejność prób: nil → bool → int64 (`^-?[0-9]+$`; przepełnienie → próba double) → double (gramatyka spec §3.1 pkt 5, wynik skończony) → string.

### 3.2 Unie dyskryminowane → enumy z associated values

Wzorzec dla każdej unii (`WidgetDTO`, `ComponentLedDTO`, `ValueRefDTO`, `ActionRefDTO`):

```swift
public enum WidgetDTO: Decodable, Sendable {
    case valueV2(ValueV2WidgetDTO)
    case onOff(OnOffWidgetDTO)
    // … 14 przypadków (spec §3.5)

    private enum CodingKeys: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
        let type = try decoder.container(keyedBy: CodingKeys.self)
                              .decode(String.self, forKey: .type)
        switch type {
        case "VALUE_V2": self = .valueV2(try ValueV2WidgetDTO(from: decoder))
        case "ON_OFF":   self = .onOff(try OnOffWidgetDTO(from: decoder))
        // …
        default: throw GrentonModelError.unknownDiscriminator(type)
        }
    }
}
```

### 3.3 Tolerancyjne parsowanie widgetów (spec §3.6)

Strona dekoduje widgety odpornie — element, który rzuci, jest pomijany:

```swift
public struct PageDTO: Decodable, Sendable {
    public let name: String
    public let icon: String
    public let isFullscreenWidget: Bool
    public let widgets: [WidgetDTO]

    public init(from decoder: Decoder) throws {
        // … zwykłe pola …
        var raw = try container.nestedUnkeyedContainer(forKey: .widgets)
        var result: [WidgetDTO] = []
        while !raw.isAtEnd {
            if let w = try? raw.decode(WidgetDTO.self) { result.append(w) }
            else { _ = try? raw.decode(AnyDecodableSkip.self) }  // przesuwa kursor
        }
        self.widgets = result
    }
}
```

`AnyDecodableSkip` to pusta struktura dekodująca cokolwiek (konieczna — `UnkeyedDecodingContainer` nie przesuwa indeksu po nieudanym `decode`). Uwaga implementacyjna: to znany pitfall Codable; pokryć testem „widget nieznanego typu w środku listy nie zjada następnych".

Nazwy pól JSON są camelCase 1:1 (`serialNumber`, `pushNotifications`) — bez `keyDecodingStrategy`, klucze wprost.

### 3.4 Typy domenowe

```swift
public enum ValueRef: Hashable, Sendable {
    case variable(cluId: String, name: String)
    case attribute(cluId: String, objectName: String, index: String)
}

public struct ActionRef: Sendable {
    public enum Call: Sendable {
        case variable(index: String)
        case attribute(index: String)
        case method(index: String)
        case script
    }
    public let cluId: String
    public let objectName: String
    public let call: Call
    public let event: ActionEvent      // .click / .on / .off
    public var value: String           // mutowalne kopiowanie przy nadpisaniu (spec §6.3.10)
}
```

`ValueRef: Hashable` — bezpośrednio klucz słowników StateStore (odpowiednik dwóch typów kluczy referencji: wariant enuma niesie tę informację).

## 4. GrentonRuntime

### 4.1 Cipher (spec §5.1)

```swift
public protocol GrentonCipher: Sendable {
    func encrypt(_ plaintext: Data) -> Data?
    func decrypt(_ ciphertext: Data) -> Data?
}

public struct AesCbcCipher: GrentonCipher {
    public init(keyBase64: String, ivBase64: String) throws { /* walidacja 16/24/32 + 16 */ }
}
```

Implementacja: `CCCrypt(kCCEncrypt/kCCDecrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding, …)` — CommonCrypto sam dokłada i zdejmuje padding PKCS7 oraz odrzuca zły padding przy deszyfracji (status `kCCDecodeError`). Dodatkowo po deszyfracji własna walidacja ścisła nie jest potrzebna (robi ją CC), ale test złotych wektorów (spec §9.1) obowiązuje bezwzględnie. Protokół `GrentonCipher` istnieje po to, by (a) testy mogły podstawić szyfr tożsamościowy, (b) przyszły port linuksowy podmienił backend na `_CryptoExtras`.

### 4.2 Wire i wiadomości (spec §5.2–5.3)

Czyste funkcje/typy — bez I/O, w 100% testowalne stringowo:

```swift
enum WireFrame {
    static func request(msgId: String, payload: String) -> String    // "req::\(msgId):\(payload)"
    static func parseResponse(_ s: String) -> Response?              // resp + 4 części, msgId lowercased
}

enum Payloads {
    static func checkAlive() -> String
    static func clientRegister(sessionId: Int, keys: [ValueRef]) -> String
    static func action(_ a: ActionRef) -> String                     // 4 warianty (spec §5.3.4)
    static func clientDestroy(sessionId: Int) -> String
    static func registrationChunks(_ keys: [ValueRef], frameLimit: Int) -> [[ValueRef]]   // podział po bajtach ramki (spec §5.4.2)
    static func parseClientReport(_ payload: String) -> ClientReport?                      // (sessionId, values)
}
```

### 4.3 Transport UDP (spec §7.1)

```swift
protocol UdpSocket: Sendable {
    var incoming: AsyncStream<Data> { get }
    func send(_ datagram: Data) async throws
    func close()
}
protocol UdpSocketFactory: Sendable {
    func open(host: String, port: UInt16) async throws -> UdpSocket
}
```

Implementacja produkcyjna — **dwa tryby za tym samym protokołem `UdpSocket`**:

- **Domyślny:** `NWConnection(host:port:using: .udp)` — connected-UDP binduje port efemeryczny per połączenie i filtruje nadawcę do peera (spec Δ §7.1). Sesja ma jeden taki socket: notyfikacje wracają na port źródłowy rejestracji, czyli na niego (spec §5.3.2).
- **Fallback (pełnoprawny, testowany):** `AnySourceUdpSocketFactory` — **jeden niepodłączony socket BSD** (bind na porcie efemerycznym, `sendto` do CLU, `recv` od dowolnego nadawcy przez `DispatchSourceRead`). Wymagany przez spec §7.1: CLU z wieloma interfejsami może raportować z innego adresu źródłowego, a connected-UDP takie datagramy odrzuci. **Dlaczego nie `NWListener` + `NWConnection` na wspólnym porcie:** przy `SO_REUSEPORT` kernel rozdziela datagramy z obcych źródeł między oba sockety **niedeterministycznie** — część trafia w socket połączony, który je odrzuca (zweryfikowane empirycznie: taka architektura gubiła datagramy w ~20% przebiegów). Jeden niepodłączony socket odbiera wszystko na swoim porcie i wysyła z tego samego portu (wymóg protokołu: raporty wracają na port źródłowy rejestracji). Wybór trybu konfigurowalny na poziomie `GrentonSystem`; suite transportowa testuje odbiór z obcego portu źródłowego na loopbacku.

Wspólne dla obu trybów:

- pętla `receiveMessage` rekurencyjna pompuje datagramy do sesji;
- `stateUpdateHandler`: `.failed`/`.cancelled` kończy strumień (sesja tłumaczy to na `ConnectionClosed` dla pending).

**Jeden odbiorca na socket.** `AsyncStream` ma semantykę jednego konsumenta — dlatego strumień `incoming` socketu czyta **wyłącznie jedna pompa (router) należąca do sesji**. Router deszyfruje, parsuje ramkę i rozdziela: `msg_id` znaleziony w `pending` → wznowienie kontynuacji; ramka `clientReport` → numer subskrypcji → emisja raportu z kluczami chunka o tym numerze (spec §5.4.3). Żadna operacja (w szczególności `register` czekający na odpowiedź) **nie czyta socketu bezpośrednio** — czeka na kontynuacji zarejestrowanej u routera. To eliminuje wyścig konkurujących konsumentów.

### 4.4 `CluSession` — aktor (spec §5.4)

```swift
public actor CluSession {
    public init(clu: Clu, cipher: GrentonCipher,
                sockets: UdpSocketFactory, clock: any Clock<Duration>,
                random: RandomSource, logger: GrentonLogger)

    public func start() async throws     // idempotentne; otwiera socket główny + ping początkowy (spec §5.4.5)
    public func ping() async -> Bool
    public func register(_ keys: [ValueRef]) async -> [RegistrationSlot] // .failed | .value(GrentonValue) — spec §5.4.2
    public func execute(_ action: ActionRef) async throws
    public func stop() async             // idempotentne; po stop() dozwolony ponowny start()
    public var state: SessionState { get }  // .idle/.starting/.ready/.degraded/.stopped — spec §5.4.5

    public func reports() -> AsyncStream<(keys: [ValueRef], slots: [RegistrationSlot])>  // strumień per subskrybent
}
```

Decyzje:

- **Korelacja żądanie–odpowiedź:** `pending: [String: CheckedContinuation<String, Error>]` wewnątrz aktora; kontynuacje wznawia **router socketu** (§4.3), nigdy bezpośredni odczyt socketu przez operację. Timeout 5 s przez wyścig: task odpowiedzi vs `clock.sleep` w `withThrowingTaskGroup` — pierwszy wygrywa, drugi anulowany; wpis w `pending` sprzątany w `defer`. `any Clock<Duration>` wstrzyknięty → testy używają zegara manualnego i nie czekają realnych sekund.
- **Reentrancja aktora.** Aktor Swifta jest reentrantny na `await` — sama izolacja **nie** serializuje operacji wieloetapowych (spec §5.4.5): dwie równoległe rejestracje mogłyby pomieszać numery chunków, `stop()` mógłby przeciąć `register` w pół. Sesja utrzymuje jawny `SessionState` (`idle/starting/ready/degraded/stopped` + `operationInProgress`) i **bramkę serializującą** dla `start`/`register`/`stop` (kolejka kontynuacji lub `AsyncSemaphore`); wywołanie w trakcie operacji czeka, `register` zgłoszony w czasie trwającego `register` jest łączony (coalescing do jednego przebiegu z najświeższym zbiorem kluczy). Przejścia stanów i retry w `degraded` (ponowne otwarcie socketu głównego przy tiku pingu) — dokładnie wg spec §5.4.5.
- **Chunk:** struktura `{number, keys}`; tabela `number → keys` obejmuje każdy numer, który CLU może jeszcze obsługiwać (od wysłania żądania do `clientDestroy`), i to po niej router kieruje raporty. Licznik numerów zerowany w `start()`, najwyżej 999999 (spec §5.4.2 pkt 1).
- **`keepAliveId`** losowany w `init` z `RandomSource`; ping używa go jako `msgId` (spec §5.3.1).
- **`register`** — implementuje sekwencję spec §5.4.2: podział po bajtach ramki (`Payloads.registrationChunks`, domyślnie 1471 B, `registerFrameLimit` może go obniżyć) → numeracja (chunk z identyczną listą zachowuje numer, inny dostaje nowy) → chunki **po kolei** z socketu głównego jako `clientRegister(0,0,{numer},…)` → `clientDestroy` numerów, których nowa lista nie używa. Wyniki składane pozycyjnie w `[RegistrationSlot]`. Re-rejestracja 30 s od wysłania pierwszego chunka poprzedniej rejestracji (`Clock.deadline(after:)`).

### 4.5 `StateStore` — klasa z blokadą, nie aktor (spec §5.5)

```swift
public final class StateStore: @unchecked Sendable {   // wewnętrznie NSLock/OSAllocatedUnfairLock
    public func registerKey(_ ref: ValueRef)                       // idempotentne, kolejność zachowana
    public func subscriptionOrder(cluId: String) -> [ValueRef]
    public func updateKeys(_ keys: [ValueRef], _ slots: [RegistrationSlot]) // .failed pomijane, .value(x) nadpisuje (także .null)
    public func value(for ref: ValueRef) -> GrentonValue?          // SYNCHRONICZNE — patrz niżej
    public func changes() -> AsyncStream<StateChange>              // NOWY strumień per wywołanie
}
public struct StateChange: Sendable {
    public let cluId: String
    public let key: ValueRef
    public let oldValue: GrentonValue?
    public let newValue: GrentonValue
}
```

Dwie decyzje wynikające z izolacji aktorów:

1. **Blokada zamiast aktora.** Encje urządzeń (§5.1) mają synchroniczne gettery stanu (`isOn`, `brightness`) — aktor wymusiłby `await` na każdym odczycie i zablokował użycie w kontekstach synchronicznych (SwiftUI `body`). Spec §5.6 wymaga tylko bezpieczeństwa współbieżnych odczytów przy zserializowanych zapisach — krótka blokada wokół słowników spełnia to tanio. Zapisy i tak przychodzą z jednego miejsca (sesje).
2. **Strumień per subskrybent.** `AsyncStream` obsługuje jednego konsumenta — dlatego `changes()` **tworzy nowy strumień przy każdym wywołaniu**; store trzyma listę kontynuacji subskrybentów (pod tą samą blokadą), emisja iteruje po liście, `onTermination` usuwa wpis. Polityka bufora: `.bufferingNewest(64)` — wolny subskrybent gubi najstarsze zdarzenia, co jest bezpieczne, bo świeży stan zawsze czyta się ze store'a, nie ze zdarzeń.

Emisja `StateChange` tylko przy faktycznej zmianie (`oldValue != newValue`). Ten sam wzorzec per-subskrybent stosują `CluSession.reports()` i `GrentonSystem.events()`.

### 4.6 `GrentonSystem` — fasada (odpowiednik koordynatora)

```swift
public actor GrentonSystem {
    public init(interface: MobileInterface,
                sockets: UdpSocketFactory = NetworkUdpSocketFactory(),
                logger: GrentonLogger = .default)

    public func start() async throws     // connect + ping + register + pętle; idempotentne
    public func stop() async             // idempotentne; po stop() wolno start() ponownie (cykl tła iOS)
    public nonisolated let descriptors: [DeviceDescriptor]   // czyste mapowanie DTO (§5.2), dostępne bez start()
    public nonisolated let devices: [any GrentonDevice]      // deskryptory zbindowane do store/sesji
    public func events() -> AsyncStream<DeviceStateChanged>  // strumień per subskrybent (§4.5)
}
```

Pętle utrzymania (spec §5.4.4): dwa `Task`y wewnątrz aktora, `try await clock.sleep(for: .seconds(5/45))`, kończone anulowaniem w `stop()`; `CancellationError` przerywa pętlę czysto. Zmiana zbioru subskrypcji → natychmiastowe `register` (spec Δ).

## 5. GrentonDevices

### 5.1 Kształt urządzeń

```swift
public protocol GrentonDevice: Sendable {
    var id: String { get }
    var kind: DeviceKind { get }
    var name: String { get }
    var entities: [any GrentonEntity] { get }
}
public protocol GrentonEntity: Sendable {
    var id: String { get }            // "{widgetId}_{sufiks}" — kontrakt ze spec §6.1
    var name: String { get }
}
```

Konfiguracja użytkownika (device class, jednostki) **nie istnieje w Core** (spec §6.4) — adapter trzyma własną mapę `entityId → config`; encje są dzięki temu w pełni niemutowalne.

Encje konkretne jako `final class` o **niemutowalnych polach** (`let stateRef`, `let onAction` — szablony `ActionRef` są stałe; komenda buduje kopię z nową wartością, nigdy nie mutuje szablonu, co czyni klasę uczciwie `Sendable`):

```swift
public final class SwitchEntity: GrentonEntity {
    public var isOn: Bool? { get }                 // synchroniczne: boolFromOnOff(store.value(stateRef)) — store z blokadą, §4.5
    public func turnOn() async throws              // execute(kopia onAction)
    public func turnOff() async throws
    public func updates() -> AsyncStream<Void>     // per subskrybent; filtrowane z StateStore.changes() po własnych ref-ach
}
```

Analogicznie: `DimmableLightEntity` (brightness 0…1, spec §6.3.2), `HsbLightEntity` (§6.3.3), `ContactSensorEntity` (§6.3.4), `SensorEntity` (§6.3.5–6), `NumberSettingEntity` (§6.3.7), `CoverEntity` (§6.3.8), `StateSensorEntity`/`TriggerEntity` (§6.3.9), `SceneTriggerEntity` (§6.3.10 — `run()`, `run(parameter:)` na **kopii** ActionRef), `CameraEntity` (§6.3.11 — samo `streamURL`).

Wszystkie normalizacje (mapRange, koercje, odwrócenie tilta, zaokrąglenia precision) — wyłącznie tutaj, zgodnie ze spec §6; adapter (SwiftUI/HomeKit) już niczego nie przelicza.

### 5.2 Mapper — dwa etapy (spec §6.1)

1. `DeviceMapper.descriptors(for interface:) -> [DeviceDescriptor]` — **czysta funkcja na DTO**: reguły kompletności ze spec §6.3 (LED bez kompletu komponentów → urządzenie bez encji, puste `components` kamery/legacy rolety → pomiń), zero uchwytów do Runtime. Testowalna bez sieci na fixturach.
2. `DeviceBinder.bind(descriptors, store:, sessions:) -> [any GrentonDevice]` — fabryka encji żywych; rejestruje `ValueRef`-y w store.

### 5.3 Formatowanie wartości akcji

Jedna funkcja `formatDeviceNumber(_ v: Double, precision: Int) -> String`, **domyślnie w 100% zgodna z referencją** — odtwarza Pythonowe `str(round(v, p))` z zaokrągleniem half-to-even, w tym `precision: 0` → `"5.0"` (Python `round(x,0)` zwraca float). Test zgodności stringów payloadów (spec §9.5 pkt 4) porównuje 1:1 z referencją. Format „czysty" (`"5"`) dostępny za flagą — włączany dopiero po weryfikacji na żywym CLU w milestone 7 (spec §10 pkt 3).

### 5.4 Integracja z UI (poza Core)

Core nie używa `@Observable`/Combine — tylko `AsyncStream`. Cienki adapter aplikacyjny (np. `@Observable final class SwitchViewModel`) subskrybuje `updates` i przepisuje stan; dzięki temu Core nie podnosi minimalnych platform i nie narzuca frameworka UI.

## 6. GrentonProvisioning

```swift
public struct ProvisioningClient: Sendable {
    public init(host: String, port: UInt16 = 9998, session: URLSession = .shared)
    public func fetchInterface(pin: String) async throws -> MobileInterface
}
```

- `URLSession.data(from:)`; status 401 → `.authenticationFailed`, inne ≠200 → `.connection`; mapowanie błędów spec §4.2.
- ZIP: `ZIPFoundation.Archive(data:accessMode:.read)` → wpis `mygrenton/data.json` → `JSONDecoder` → `MobileInterface`.
- **Limity spec §4.3 egzekwowane jawnie:** rozmiar ciała odpowiedzi sprawdzany przed otwarciem archiwum, `uncompressedSize` wpisu przed ekstrakcją (10 MB każdy; przekroczenie → `.invalidData`); ścieżka wpisu porównywana dokładnie ze stałą, bez normalizacji.
- **Import z pliku projektu (spec §4.5, od 0.8.0):** `ProjectFile(data:)` otwiera archiwum `.omp`, parsuje `properties.xml` i `system.xml` (własny DOM na `XMLParser`: arena węzłów w kolejności dokumentu, referencje `reference → id` rozwiązywane leniwie, `DOCTYPE` wykrywany po zdekodowaniu prologu w kodowaniu, które wybrałby parser; niedekodowalny dokument i każda deklaracja DTD → `.invalidData`) i listę interfejsów (`nodes/{n}/data.json` czytane własnym ścisłym parserem JSON — duplikaty kluczy, `NaN`, liczby poza Int64 i niekończone double → `.invalidData`). `interface(id:)` konwertuje interfejs regułami §4.5.6 do drzewa JSON, serializuje je i dekoduje jak pobrany `data.json`, więc dalej nic nie zależy od źródła. Limity (64 MiB na plik, wpis i sumę wpisów; 10 000 wpisów) są egzekwowane w trakcie dekompresji: strumień jest trzymany przy rozmiarze z nagłówka, a inny rozmiar końcowy odrzuca wpis. Nagłówki sekcji (`HEADER`) są od tej wersji zachowane w `PageDTO.items`, bo projekcja zgodności §4c wymienia je wśród widgetów, które przeszły parsowanie.
- **Uwaga ATS (iOS):** OM mówi czystym HTTP. Aplikacja musi dodać wyjątek App Transport Security (`NSAllowsLocalNetworking = true` w `NSAppTransportSecurity`) — udokumentować w README pakietu; bez tego `URLSession` odrzuci połączenie.

## 7. Obsługa błędów

Enumy per moduł, lustrzane wobec spec §8:

```swift
public enum ProvisioningError: Error { case authenticationFailed, connection(underlying: Error?), invalidData(String) }
public enum CryptoError: Error { case invalidKeyMaterial }
public enum SessionError: Error { case notConnected, connectionClosed, timeout }
public enum GrentonModelError: Error { case unknownDiscriminator(String) }
```

Zasady dostarczania błędów jak w spec §8: ścieżka odbioru połyka i loguje, ścieżka żądania rzuca, pętle logują i lecą dalej.

## 8. Testy

- **swift-testing**, fixtury w `Tests/Fixtures` przez `Bundle.module` — te same pliki co w repo spec (złote wektory AES §9.1 jako JSON, `data.json` §9.3, tabela castowania §9.2).
- **FakeCLU**: w pamięci (`InMemoryUdpSocket`) + ten sam `AesCbcCipher`; scenariusze ze spec §9.4. Odpowiada na socket nadawcy, notyfikacje niosą numer rejestracji, zapisuje `clientDestroy` — routing po numerze testuje się realnie.
- Testy czasowe (timeout 5 s, pętle 5/30 s) na wstrzykniętym zegarze testowym (`Clock` manualny) — zero realnego czekania.
- Checklist zgodności spec §9.5 jako osobny suite `ConformanceTests` — to jest definicja „port skończony".

## 9. Uwagi platformowe (iOS/macOS)

1. **Local Network Privacy (iOS 14+):** pierwszy unicast UDP do LAN wywołuje systemowy prompt. Aplikacja hostująca musi mieć `NSLocalNetworkUsageDescription` w Info.plist (bez multicast entitlement — sam unicast go nie wymaga). Odmowa użytkownika = `NWConnection` w stanie `waiting/failed` — sesja przejdzie w `degraded` (spec §5.4.5); udokumentować w README.
2. **Tło:** iOS zawiesza aplikację → sockety UDP umierają, subskrypcje po stronie CLU wygasają. Wzorzec dla aplikacji: `stop()` przy przejściu w tło, `start()` przy powrocie (sesja jest tania: ping + register). Core musi więc wspierać wielokrotny cykl start/stop na tej samej instancji.
3. **ATS** dla HTTP do OM — §6.
4. macOS (sandbox): entitlement `com.apple.security.network.client`.

## 10. Mapa implementacja referencyjna → Swift

| Python (referencja) | Swift |
|---|---|
| `state.py` (`GrentonValue`, casting, `GrentonCluState`) | `GrentonModel/GrentonValue.swift`, `GrentonRuntime/StateStore.swift` |
| `domain/cipher.py` | `GrentonRuntime/AesCbcCipher.swift` |
| `domain/api/clu_messages/*` | `GrentonRuntime/WireFrame.swift`, `Payloads.swift` |
| `domain/api/clu.py` (`GrentonCluApi`, protokół UDP) | `GrentonRuntime/CluSession.swift`, `NetworkUdpSocket.swift` |
| `coordinator.py` (pętle, routing raportów) | `GrentonRuntime/GrentonSystem.swift` |
| `domain/api/object_manager.py` | `GrentonProvisioning/ProvisioningClient.swift` |
| `dto/**` | `GrentonModel/DTO/**` |
| `domain/{clu,action,state_object,enums}.py` | `GrentonModel/{Clu,ActionRef,ValueRef,Enums}.swift` |
| `mappers/**` | `GrentonDevices/DeviceMapper.swift` |
| `domain/entities/**` (logika normalizacji) | `GrentonDevices/Entities/**` |
| encje HA / platformy / config flow | **poza Core** — adapter aplikacji |

## 11. Kolejność implementacji

Każdy milestone kończy się zielonym testem; kolejność minimalizuje pracę „na wiarę":

1. **GrentonModel** — typy + Codable + tolerancyjne parsowanie; test: fixtura `data.json`, tabela castowania.
2. **Cipher** — CommonCrypto; test: złote wektory AES (spec §9.1).
3. **Wire + Payloads** — czyste stringi; test: payloady register/akcji 1:1 ze spec.
4. **CluSession + StateStore vs FakeCLU** — ping, register chunkowany, raporty, akcje, timeouty (zegar testowy).
5. **GrentonProvisioning** — na nagranym ZIP-ie z prawdziwego OM (fixture).
6. **GrentonDevices** — mapper + normalizacje; testy round-trip (dimmer, HSB, tilt).
7. **`grenton-cli`** — smoke test na żywej instalacji użytkownika: listuje urządzenia, śledzi raporty, wykonuje akcję; tu weryfikujemy pytania otwarte (format liczb §5.3, zachowanie promptu Local Network).

## 12. Ryzyka i pytania otwarte

| Ryzyko | Mitygacja |
|---|---|
| Format liczb w payloadach (`5` vs `5.0`) | **domyślnie format referencyjny `5.0`** (§5.3); format czysty za flagą, włączany po teście na żywym CLU w M7 |
| `NWConnection` connected-UDP a raporty z innego adresu źródłowego CLU (np. CLU z wieloma interfejsami) | tryb any-source na sockecie BSD (odbiór dowolnego nadawcy) jest **pełnoprawnym, testowanym trybem** za tym samym protokołem `UdpSocket` (§4.3), przełączalnym w konfiguracji |
| ZIPFoundation jako jedyna zależność | izolowana w Provisioning; limity rozmiaru wg spec §4.3; w razie potrzeby wymienialna na ręczny parser ZIP (deflate przez `Compression.framework`) |
| Prompt Local Network odrzucony przez użytkownika | stan `degraded` + dokumentacja dla aplikacji (nie da się wykryć wprost — tylko timeouty) |
| Linux w przyszłości | `GrentonCipher` jako protokół — backend `_CryptoExtras` (AES.\_CBC) dodany jako conditional dependency z tymi samymi złotymi wektorami w CI; do tego czasu pakiet **deklaruje wyłącznie platformy Apple** w `Package.swift` |

## 13. TODO

Wnioski z przeglądu dwóch innych integracji Grentona z Home Assistant: `onesmarthome-ha` (MIT; forma mobilna, jak my) i `grenton-native` (GPL-3.0; forma Object Managera, klucz z pliku `.omp`). Z `grenton-native` bierzemy tylko fakty o protokole, nie kod.

1. ✅ **Zrobione (spec 0.7.0):** argumenty to `(ip, port, sesja, klucze)`, zmierzone na 6 CLU trzech generacji firmware (`Examples/probe-register`). Notatka pierwotna: **Semantyka argumentów `clientRegister` (spec §5.3.2).** `grenton-native` używa formy OM `clientRegister("<ip klienta>",<port raportów>,<sesja>,{…})`. Hipoteza: nasze `(0,{sessionId},1,…)` to w rzeczywistości `(ip, port, sesja)`, gdzie `0,0` oznacza „odsyłaj na adres i port nadawcy”, a `1` to sesja (stąd zawsze `clientReport:1:`). Niezerowy „sessionId” byłby wtedy portem, na który CLU wysyła push. Do sprawdzenia na żywo: forma z jawnym IP i portem gniazda rejestracji, port różny od gniazda, różne wartości trzeciego argumentu na tym samym gnieździe. Wynik może przepisać §5.3.2, §5.3.3, §10.6 i założenie „socket per chunk”.
2. ✅ **Zrobione (spec 0.7.0):** `clientDestroy(0,0,{numer})` przy `stop()` i dla numerów, których nowa lista nie używa. Notatka pierwotna: **`clientDestroy` przy `stop()` i przy zamykaniu endpointów przed re-rejestracją.** Forma OM to `SYSTEM:clientDestroy("<ip>",<port>,<sesja>)`; odpowiednik dla formy mobilnej do ustalenia razem z punktem 1. Spec first: nowa wiadomość w §5.3, scenariusze w zestawie `session`.
3. **Porównanie mapowania z `onesmarthome-ha`.** Obsługujemy już wszystkie jego widgety (§6.3). Porównać semantykę tam, gdzie się różnimy: `ROLLER_SHUTTER_V3` (lamele, stop), `MULTISENSOR`, `SCENE_DOUBLE`, `*_DOUBLE`, format liczb w akcjach (oni: precyzja 0 → `"5"`, por. §10.3). Każdą rozbieżność rozstrzygnąć w specyfikacji albo zapisać jako Δ.
4. **Import z pliku `.omp` w `GrentonProvisioning`.** Drugie źródło klucza i topologii: `properties.xml` → `projectCipherKey` (`keyBytes`/`ivBytes`), `system.xml` → CLU (`nameOnCLU`, `ipAddress`) oraz obiekty z cechami. Nie wymaga PIN-u ani otwartego OM, ale nie niesie widgetów myGrenton. Najpierw decyzja, jak takie obiekty mają się mapować na urządzenia kanoniczne (§6.6 obiekty fizyczne?).
