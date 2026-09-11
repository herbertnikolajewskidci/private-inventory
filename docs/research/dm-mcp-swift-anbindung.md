<!-- markdownlint-disable MD013 -->
# dm MCP-Server-Anbindung aus Swift (Streamable HTTP, ohne Framework)

Recherche-Stand: 2026-09-11. Alle Schnittstellen und Aufrufsequenzen wurden
an diesem Tag live gegen `https://mcp.dm.de/mcp` per `curl` verifiziert.

## TL;DR

- **Ja, die Anbindung geht vollständig und sauber mit plain `URLSession`**,
  ohne externe MCP-Frameworks oder SDK-Dependencies.
- **Transport & Format**: Streamable HTTP Transport (MCP-Spezifikation).
  dm antwortet auf POST-Requests mit `Content-Type: text/event-stream` (SSE).
  Für One-Shot-Tool-Calls (`initialize`, `tools/call`) reicht normales
  `URLSession.data(for:)`; der Body enthält standardmäßig eine einzelne
  `data: {...}`-Zeile, die als JSON dekodiert wird. Ein dauerhafter
  SSE-Stream (`URLSession.bytes(for:)`) ist für Barcode-Lookups nicht nötig.
- **Session-Handling**: Der Server erzwingt eine Session. Der Handshake
  liefert den Header `Mcp-Session-Id`. Folgerequests ohne diesen Header
  scheitern mit `HTTP 400 (-32600 "Missing session ID")`. Abgelaufene oder
  unbekannte Sessions quittiert der Server mit `HTTP 404 (-32600 "Session
  not found")`.
- **Zwei kritische Stolpersteine**:
  1. **GTIN-Datentyp**: `getProductDetails` verlangt `gtins` zwingend als
     `[Int64]` (JSON-Schema: `integer, format: int64`). Strings wie
     `["4066447966008"]` scheitern mit Schema-Validierungsfehler im Payload
     (`isError: false`).
  2. **Ergebnisformat TOON**: Die Produktdaten liegen nicht als JSON-Objekt
     vor, sondern als Pipe-separierter TOON-String (*Token-Oriented Object
     Notation*) im Feld `result` des Content-Texts.
- **Performance**: Ein einzelner Tool-Call dauert ~0,39 s (TTFB ~0,19 s).
  Die Session kann im Speicher gehalten und bei `HTTP 404` transparent
  neu initialisiert werden.

---

## 1. Primärquellen & Spezifikationsgrundlage

- **dm MCP-Server Landingpage**: <https://mcp.dm.de/>
  - Endpunkt: `https://mcp.dm.de/mcp`
  - Server-Info live: `dm-drogeriemarkt` Version `3.4.7`
  - Auth: Öffentlich, kein API-Key, keine Authentifizierung
- **MCP Spezifikation (Streamable HTTP Transport)**:
  <https://modelcontextprotocol.io/specification/2025-06-18/basic/transports#streamable-http>
  - Beschreibt das Zusammenspiel von HTTP POST für Client-to-Server-Nachrichten
    und optionalen GET-SSE-Streams für Server-Events.
- **MCP Spezifikation (Lifecycle)**:
  <https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle>
  - Handshake: `initialize` (Request) → Result → `notifications/initialized`
    (Notification).
- **TOON Spezifikation (Token-Oriented Object Notation)**:
  <https://github.com/toon-format/toon>
  - Kompaktes, tabellarisches Format für LLM-Kontexte, das dm für Tool-Ergebnisse
    einsetzt (`[count]{header|fields}:\n  value1|value2|...`).

---

## 2. MCP Streamable HTTP Lifecycle im Detail

### 2.1 Handshake (`initialize` + `notifications/initialized`)

1. **Client POST `initialize`**:
   - `Content-Type: application/json`
   - `Accept: application/json, text/event-stream`
   - Payload: Client-Info und unterstützte `protocolVersion`.
   - Bei Anfrage von `2025-06-18` oder `2026-07-28` verhandelt dm
     `2025-06-18` bzw. `2025-11-25`.
2. **Server-Antwort**:
   - Status `HTTP 200 OK`
   - Header: `Mcp-Session-Id: <uuid>` (z. B. `5509759df3ce45ddac0bc795d36090e8`)
   - Header: `Content-Type: text/event-stream`
   - Body: SSE-Event mit JSON-RPC-Resultat (Server-Capabilities, Server-Version).
3. **Client POST `notifications/initialized`**:
   - Notification (ohne `id` im JSON-RPC).
   - Header: `Mcp-Session-Id: <uuid>`, `MCP-Protocol-Version: <verhandelte_version>`.
   - Server antwortet mit `HTTP 202 Accepted` und leerem Body (`content-length: 0`).

### 2.2 Tool-Aufruf (`tools/call`)

- Client POST an dieselbe URL mit Header `Mcp-Session-Id: <uuid>`.
- Methode: `tools/call`.
- Argumente für `getProductDetails`: `{"gtins": [4066447966008]}` (als Integer!).
- Server antwortet mit `HTTP 200 OK` und `Content-Type: text/event-stream`.
- Body enthält JSON-RPC-Ergebnis mit TOON-formatiertem Text.

### 2.3 Session-Termination (`DELETE`)

- MCP erlaubt das Beenden der Session via `HTTP DELETE https://mcp.dm.de/mcp`
  mit Header `Mcp-Session-Id: <uuid>`.
- Server antwortet mit `HTTP 200 OK`.
- Für iOS-Clients: Optional beim Aufräumen oder App-Backgrounding; bei
  Ablauf (`HTTP 404`) einfach neu initialisieren.

---

## 3. Verifizierte Aufruf-Sequenz (Live-Belege per curl)

### 3.1 Schritt 1: Initialize

**Request:**

```bash
curl -sS -D - -X POST https://mcp.dm.de/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
      "protocolVersion": "2025-06-18",
      "capabilities": {},
      "clientInfo": {
        "name": "private-inventory-research",
        "version": "0.1.0"
      }
    }
  }'
```

**Response (Header & Body):**

```http
HTTP/2 200 
content-type: text/event-stream
mcp-session-id: 5509759df3ce45ddac0bc795d36090e8
date: Fri, 11 Sep 2026 17:29:38 GMT

event: message
data: {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{},"logging":{},"prompts":{"listChanged":true},"resources":{"subscribe":false,"listChanged":true},"tools":{"listChanged":true},"extensions":{"io.modelcontextprotocol/ui":{}}},"serverInfo":{"name":"dm-drogeriemarkt","version":"3.4.7","websiteUrl":"www.dm.de"},"instructions":"Use this MCP server to find products in the online catalogue of dm-drogeriemarkt. Do not include personal data of customers (e.g. names, addresses, or contact details) in any queries."}}
```

### 3.2 Schritt 2: Initialized Notification

**Request:**

```bash
curl -sS -D - -X POST https://mcp.dm.de/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'Mcp-Session-Id: 5509759df3ce45ddac0bc795d36090e8' \
  -H 'MCP-Protocol-Version: 2025-06-18' \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
```

**Response:**

```http
HTTP/2 202 
content-length: 0
```

*(Kein Response-Body, Status 202 signalisiert erfolgreiche Quittierung).*

### 3.3 Schritt 3: `tools/call` für `getProductDetails` (Treffer)

**Request:**

```bash
curl -sS -D - -X POST https://mcp.dm.de/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'Mcp-Session-Id: 5509759df3ce45ddac0bc795d36090e8' \
  -H 'MCP-Protocol-Version: 2025-06-18' \
  -d '{
    "jsonrpc": "2.0",
    "id": 5,
    "method": "tools/call",
    "params": {
      "name": "getProductDetails",
      "arguments": {
        "gtins": [4066447966008]
      }
    }
  }'
```

**Response:**

```http
HTTP/2 200 
content-type: text/event-stream

event: message
data: {"jsonrpc":"2.0","id":5,"result":{"content":[{"type":"text","text":"{\"instruction\":\"Always include a dm.de link for any product(s):...\",\"result\":\"[1]{dan|gtin|productName|brand|found|errorMessage|productUrl|image|imageBackgroundColor|productType|weight|volume|description|keyBenefits|countryOfOrigin|foodIngredients|preparation|nutritionFacts|allergens|additives|nonFoodIngredients|applicationInstructions|warnings|hazardWarnings|careLabel|productFeatures|isSustainable}:\\n  1569035|4066447966008|Shampoo Ultra Sensitive, 250 ml|Balea med|true||\\\"https://www.dm.de/applink/p/d/1569035/balea-med-shampoo-ultra-sensitive?appPageType=productdetails&appProductId=1569035&wt_mc=dm-mcp\\\"|\\\"https://products.dm-static.com/images/f_auto,q_auto,c_fit,h_320,w_320/v1772150521/assets/pas/images/1fcbf079-eaca-4c6f-bf93-ba222052d98a/balea-med-shampoo-ultra-sensitive\\\"|#F1F6F9|NON_FOOD|291g|0.435l|Das Balea med Shampoo Ultra Sensitive bietet eine besonders sanfte Reinigung für Haar und empfindliche Kopfhaut...|[Mildes Shampoo für empfindliche Kopfhaut;\\\"Mit Glycerin, Panthenol & Niacinamid\\\";Besonders sanft;\\\"Ohne Silikone, Parfüm & Parabene\\\"]|Deutschland||||||\\\"Ingredients : Aqua, Coco-Glucoside, Glycerin, Sodium Coco-Sulfate, Sodium Cocoamphoacetate, Citric Acid, Panthenol, Niacinamide, Tocopherol, Ascorbyl Palmitate, Glyceryl Oleate, Hydroxypropyl Guar Hydroxypropyltrimonium Chloride, Hydrogenated Palm Glycerides Citrate, Lecithin, Sodium Benzoate, Potassium Sorbate, Sodium Chloride, Sodium Hydroxide\\\"|In das feuchte Haar einmassieren und kurz einwirken lassen. Gründlich ausspülen.||||[Vegan;Ohne Silikone]|false\"}"}],"structuredContent":{"instruction":"Always include a dm.de link for any product(s):...","result":"[1]{dan|gtin|...}"},"isError":false}}
```

### 3.4 Schritt 4: `tools/call` für unbekannte GTIN (Negativ-Treffer)

Wird eine GTIN übergeben, die im dm-Sortiment nicht existiert (z. B.
`9999999999999`), liefert der Server keinen Fehler, sondern ein reguläres
TOON-Ergebnis mit `found=false`:

```text
[1]{dan|gtin|productName|brand|found|errorMessage|productUrl...}:
  |9999999999999|||false|Product not found|||||||||||||||||||||
```

Das Flag `isError` auf JSON-RPC-Ebene bleibt `false`. Der Client erkennt
unbekannte Produkte sauber an `found=false` im TOON-Datensatz.

---

## 4. Stolpersteine & Fehleranalyse

### 4.1 Schema-Fehler: GTIN als String vs. Integer

- **Falle**: Entwickler übergeben Barcodes gewohnheitsmäßig als String
  (z. B. `"4066447966008"`).
- **Verhalten von dm**: Der Server antwortet mit `HTTP 200` und
  `isError: false`, aber im Feld `result` steht ein Validierungsfehler:
  `Tool (getProductDetails) input validation failed: Validation failed:
  JSON schema validation errors: [/gtins/0: string found, integer expected]`.
- **Lösung**: Vor dem Absenden `Int64(barcodeString)` parsen und als
  Array ganzer Zahlen übergeben: `[4066447966008]`.

### 4.2 Fehlende Session-ID (`HTTP 400`)

Wird ein Tool-Aufruf ohne Header `Mcp-Session-Id` abgesetzt, antwortet dm
mit normalem `application/json` (kein SSE):

```http
HTTP/2 400 
content-type: application/json

{"jsonrpc":"2.0","id":"server-error","error":{"code":-32600,"message":"Bad Request: Missing session ID"}}
```

### 4.3 Abgelaufene oder ungültige Session-ID (`HTTP 404`)

Ist die Session serverseitig abgelaufen oder ungültig:

```http
HTTP/2 404 
content-type: application/json

{"jsonrpc":"2.0","id":"server-error","error":{"code":-32600,"message":"Session not found"}}
```

- **Lösung für den Client**: Bei `HTTP 404` die gespeicherte Session verwerfen,
  automatisch einmalig den `initialize`-Handshake durchlaufen und den
  ursprünglichen Tool-Call wiederholen.

### 4.4 Content-Negotiation & SSE-Parsing

- dm antwortet auf POST-Requests mit `Content-Type: text/event-stream`.
- Die Response enthält die Zeile `event: message\r\ndata: {JSON}\r\n\r\n`.
- Ein One-Shot-Client muss nicht die SSE-Streaming-Infrastruktur bemühen;
  es genügt, aus den empfangenen UTF-8-Zeilen die Zeile mit Präfix `data:`
  zu isolieren und den Rest als Standard-JSON zu dekodieren.

### 4.5 TOON-Parsing (*Token-Oriented Object Notation*)

dm packt das Tool-Ergebnis in ein geschachteltes JSON-Feld `result` als
TOON-Tabelle:

```text
[1]{dan|gtin|productName|brand|found|errorMessage|productUrl|image|...}:
  1569035|4066447966008|Shampoo Ultra Sensitive, 250 ml|Balea med|true||"https://..."|"https://..."|...
```

- Spaltenköpfe sind durch Pipes (`|`) getrennt.
- Werte sind ebenfalls durch Pipes getrennt, optionale Anführungszeichen
  bei Strings (`"https://..."`).
- Felder wie Inhaltsstoffe, Marke und Produktname lassen sich durch
  Spalten-Splitting trivial und speicherschonend auslesen.

---

## 5. Swift-Implementierungsskizze (`URLSession`, ohne Dependencies)

Die folgende Implementierung zeigt einen vollständigen, autarken Client mit
Session-Caching, Re-Handshake bei Session-Ablauf und TOON-Extraktion.

```swift
import Foundation

public struct DmProductDetails: Sendable {
    public let gtin: String
    public let dan: String?
    public let name: String
    public let brand: String
    public let imageUrl: URL?
    public let productUrl: URL?
    public let ingredients: String?
    public let isFound: Bool
}

public actor DmMcpClient {
    private let endpoint = URL(string: "https://mcp.dm.de/mcp")!
    private let urlSession: URLSession
    private var sessionId: String?
    private let protocolVersion = "2025-06-18"
    private var nextRequestId: Int = 1

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    /// Löst eine GTIN/EAN auf.
    /// Führt bei Bedarf automatisch den initialize-Handshake durch.
    public func resolveProduct(gtin: String) async throws -> DmProductDetails? {
        guard let gtinInt = Int64(gtin) else {
            throw DmMcpError.invalidGtin(gtin)
        }

        if sessionId == nil {
            try await performHandshake()
        }

        do {
            return try await executeProductDetailsCall(gtinInt: gtinInt, originalGtin: gtin)
        } catch DmMcpError.sessionExpired {
            // Einmaliger Retry nach Session-Ablauf (HTTP 404)
            try await performHandshake()
            return try await executeProductDetailsCall(gtinInt: gtinInt, originalGtin: gtin)
        }
    }

    // MARK: - Handshake

    private func performHandshake() async throws {
        self.sessionId = nil
        let reqId = getNextRequestId()

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 10.0
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")

        let initBody: [String: Any] = [
            "jsonrpc": "2.0",
            "id": reqId,
            "method": "initialize",
            "params": [
                "protocolVersion": protocolVersion,
                "capabilities": [String: Any](),
                "clientInfo": [
                    "name": "private-inventory-ios",
                    "version": "1.0.0"
                ]
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: initBody)

        let (data, response) = try await urlSession.data(for: req)
        guard let httpRes = response as? HTTPURLResponse else {
            throw DmMcpError.invalidResponse
        }

        guard httpRes.statusCode == 200 else {
            throw DmMcpError.httpError(statusCode: httpRes.statusCode)
        }

        // Header-Feld case-insensitive auslesen
        guard let sid = httpRes.allHeaderFields.first(where: {
            ($0.key as? String)?.lowercased() == "mcp-session-id"
        })?.value as? String else {
            throw DmMcpError.missingSessionHeader
        }
        self.sessionId = sid

        // notifications/initialized absenden
        try await sendInitializedNotification(sessionId: sid)
    }

    private func sendInitializedNotification(sessionId: String) async throws {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 5.0
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
        req.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")

        let notifBody: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/initialized"
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: notifBody)

        let (_, response) = try await urlSession.data(for: req)
        guard let httpRes = response as? HTTPURLResponse,
              httpRes.statusCode == 202 || httpRes.statusCode == 200 else {
            throw DmMcpError.handshakeFailed
        }
    }

    // MARK: - Tool Call

    private func executeProductDetailsCall(
        gtinInt: Int64,
        originalGtin: String
    ) async throws -> DmProductDetails? {
        guard let sid = self.sessionId else {
            throw DmMcpError.missingSessionHeader
        }

        let reqId = getNextRequestId()
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 8.0
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id")
        req.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")

        let callBody: [String: Any] = [
            "jsonrpc": "2.0",
            "id": reqId,
            "method": "tools/call",
            "params": [
                "name": "getProductDetails",
                "arguments": [
                    "gtins": [gtinInt]
                ]
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: callBody)

        let (data, response) = try await urlSession.data(for: req)
        guard let httpRes = response as? HTTPURLResponse else {
            throw DmMcpError.invalidResponse
        }

        if httpRes.statusCode == 404 {
            self.sessionId = nil
            throw DmMcpError.sessionExpired
        }

        guard httpRes.statusCode == 200 else {
            throw DmMcpError.httpError(statusCode: httpRes.statusCode)
        }

        let jsonPayload = try extractJsonFromSse(data: data)
        return try parseProductDetails(json: jsonPayload, requestedGtin: originalGtin)
    }

    // MARK: - SSE & TOON Decoding

    /// Extrahiert das JSON-Objekt aus dem SSE-Payload ("data: {...}")
    private func extractJsonFromSse(data: Data) throws -> [String: Any] {
        guard let bodyString = String(data: data, encoding: .utf8) else {
            throw DmMcpError.decodingError("Ungültiges UTF-8")
        }

        let lines = bodyString.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("data:") {
                let jsonText = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if let jsonData = jsonText.data(using: .utf8),
                   let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                    return json
                }
            }
        }
        throw DmMcpError.decodingError("Kein data-Event im SSE-Stream gefunden")
    }

    /// Parst das TOON-formatierte Textfeld aus dem Tool-Ergebnis
    private func parseProductDetails(
        json: [String: Any],
        requestedGtin: String
    ) throws -> DmProductDetails? {
        guard let result = json["result"] as? [String: Any],
              let content = result["content"] as? [[String: Any]],
              let firstContent = content.first,
              let textPayload = firstContent["text"] as? String else {
            throw DmMcpError.decodingError("Struktur 'result.content[0].text' nicht gefunden")
        }

        // textPayload enthält ein inneres JSON: {"instruction":..., "result":"[1]{dan|...}"}
        guard let innerData = textPayload.data(using: .utf8),
              let innerJson = try JSONSerialization.jsonObject(with: innerData) as? [String: Any],
              let toonString = innerJson["result"] as? String else {
            throw DmMcpError.decodingError("Innerer TOON-String fehlt")
        }

        return parseToonRecord(toonString: toonString, fallbackGtin: requestedGtin)
    }

    /// Zerlegt den TOON-Record anhand der Pipe-Trennzeichen
    private func parseToonRecord(toonString: String, fallbackGtin: String) -> DmProductDetails? {
        let lines = toonString.components(separatedBy: .newlines)
        guard let headerLine = lines.first(where: { $0.contains("{") && $0.contains("}") }),
              let dataLine = lines.first(where: { $0.trimmingCharacters(in: .whitespaces).first?.isNumber == true || $0.starts(with: "  |") }) else {
            return nil
        }

        // Header parsen
        guard let headerStart = headerLine.firstIndex(of: "{"),
              let headerEnd = headerLine.firstIndex(of: "}") else {
            return nil
        }
        let headers = headerLine[headerLine.index(after: headerStart)..<headerEnd]
            .components(separatedBy: "|")

        // Werte parsen (vorsichtig: Pipe trennt Felder)
        let rawValues = dataLine.trimmingCharacters(in: .whitespaces).components(separatedBy: "|")
        guard rawValues.count >= headers.count else { return nil }

        var dict = [String: String]()
        for (idx, key) in headers.enumerated() {
            var val = rawValues[idx].trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\"") && val.hasSuffix("\"") && val.count >= 2 {
                val = String(val.dropFirst().dropLast())
            }
            dict[key] = val
        }

        let isFound = (dict["found"] == "true")
        if !isFound {
            return nil
        }

        let gtin = dict["gtin"]?.isEmpty == false ? dict["gtin"]! : fallbackGtin
        let dan = dict["dan"]?.isEmpty == false ? dict["dan"] : nil
        let name = dict["productName"] ?? ""
        let brand = dict["brand"] ?? ""
        let imgUrl = dict["image"].flatMap { URL(string: $0) }
        let prodUrl = dict["productUrl"].flatMap { URL(string: $0) }
        let ingredients = dict["nonFoodIngredients"]?.isEmpty == false ? dict["nonFoodIngredients"] : dict["foodIngredients"]

        return DmProductDetails(
            gtin: gtin,
            dan: dan,
            name: name,
            brand: brand,
            imageUrl: imgUrl,
            productUrl: prodUrl,
            ingredients: ingredients,
            isFound: true
        )
    }

    private func getNextRequestId() -> Int {
        let id = nextRequestId
        nextRequestId += 1
        return id
    }
}

public enum DmMcpError: Error {
    case invalidGtin(String)
    case invalidResponse
    case httpError(statusCode: Int)
    case missingSessionHeader
    case handshakeFailed
    case sessionExpired
    case decodingError(String)
}
```

---

## 6. Empfehlungen für Timeouts, Caching & Architektur

1. **Timeout-Budget**:
   - `initialize`: **10 Sekunden** Timeout (Handshake benötigt DNS-Auflösung
     und TLS-Setup).
   - `tools/call`: **8 Sekunden** Timeout. Der dm-Server antwortet im Normalfall
     in unter 0,4 s.
   - Gesamt-Timeout für UI-Lookup: 10 Sekunden; danach Abbruch und Fallback
     auf ungelösten Scan / Offline-Queue (gemäß ADR-0003).
2. **Session-Lebenszyklus**:
   - Die `Mcp-Session-Id` sollte im Actor/Service im Memory gehalten werden
     (keine Persistenz auf Festplatte nötig).
   - Bei App-Kaltstart oder nach `HTTP 404` wird die Session transparent
     neu verhandelt.
3. **Katalogcache & Negativ-Einträge (ADR-0002)**:
   - Jeder Treffer mit `found=true` wandert mit Name, Marke und Bild-URL in
     die lokale SwiftData/SQLite-Datenbank.
   - Jede GTIN mit `found=false` (oder Validierungsfehler) wandert in den
     Negativ-Cache, um wiederholte Netzwerkanfragen für Nicht-dm-Produkte
     zu vermeiden.
4. **Kein externer SDK-Ballast**:
   - Das offizielle MCP-Swift-SDK zieht schwergewichtige Abhängigkeiten nach
     sich (JSON-Schema-Validatoren, Stdio-Transports etc.).
   - Für die isolierte Aufgabe "GTIN-Lookup über dm-MCP" ist die oben
     gezeigte ~200-Zeilen `URLSession`-Implementierung stabiler, schlanker
     und vollständig wartbar.
