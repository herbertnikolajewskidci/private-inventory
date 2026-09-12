# Teststrategie: Test-alongside, Swift Testing, kein Netz, lesbare Tests

Der Code wird weitgehend von KI-Agenten geschrieben; der Nutzer
(DevOps, kein iOS-Hintergrund, siehe AGENTS.md) nutzt die Tests als
primäres Qualitäts-Feedback. Entscheidung: Test-alongside — Feature
und Tests landen im selben Commit, Bugfixes bekommen einen
Regression-Test, kein striktes Red-First. Framework: Swift Testing.

Getestet werden Buchungslogik (Einbuchen/Entnehmen/Verschieben),
Lookup-Kette (Katalogcache inkl. Negativ-Einträgen, Fallback-
Reihenfolge MCP → Such-API → OBF/OFF), Persistenz (GRDB-Migrationen,
Repository-Implementierung) und Scan-Session-Logik. OCR: nur das
Text-/Katalog-Matching mit Fixtures. UI: keine Unit-Tests und kein
XCUITest in v1 — stattdessen manueller Happy-Path am Gerät (Scan →
Einbuchen → Suche → Entnehmen) je Feature-Meilenstein.

Kein Netz in Tests: handgeschriebene Protokoll-Mocks plus recorded
Fixtures der dm-MCP-/Such-API-Antworten (Seed aus
`docs/research/barcode-product-data-sources.md`), Ablage unter
`Tests/Fixtures/`, Aufnahme per curl-Skript, manuelle Pflege. Der
Scanner steht hinter einem `Scanner`-Protokoll, das GTIN-Strings
liefert; VisionKit hinter der Live-Implementierung; Tests und
Simulator laufen gegen den Stub.

Qualitätssicherung gegen Spiegel-Tests (Tests, die nur die
Implementierung nachbauen): Der Review-Fokus des Nutzers liegt auf
den Tests statt auf dem Code. Property-/Invarianten-Tests für die
Buchungslogik (Menge nie negativ, Verschieben konserviert die
Gesamtsumme, Negativ-Cache unterdrückt erneuten Lookup). Englische
Testnamen mit Glossar-Termen (CONTEXT.md), Given/When/Then-
Kommentarblöcke, minimale Swift-Idiome — lesbar ohne Swift-
Tiefenwissen. Gate pro Feature: Schicht-Checkliste, kein numerisches
Coverage-Target. Beleg: Ticket „Grilling: Teststrategie für
KI-geschriebenen Code" (#6).

## Considered Options

- Striktes TDD (Red-Green-Refactor im Agent-Loop): verworfen —
  Design-Feedback ist bei Agenten-Loops dünn; Red-First kostet
  Loop-Zeit ohne messbaren Gewinn. Regression-Pflicht für Bugfixes
  bleibt.
- XCTest statt Swift Testing: verworfen — Swift Testing hat
  lesbarere Syntax und bessere Fehlermeldungen; relevant, weil der
  Reviewer kein iOS-Entwickler ist.
- XCUITest für den Scan-Flow: verworfen für v1 — flaky, und der
  Scanner-Mock (Ticket „Research: Barcode-Scanner-Stack für iOS")
  deckt die Logik ab. Re-Evaluierung, sobald CI auf macOS-Runnern
  steht (Ticket „Grilling: Projektgerüst & Repo-Layout").
- Mock-Framework (Cuckoo o. ä.) oder URLProtocol-Interception:
  verworfen — handgeschriebene Stubs sind lesbarer; die Netz-Ebene
  bleibt über Fixtures an der Client-Grenze draußen.
- Numerisches Coverage-Target: verworfen — erzeugt bei
  Agent-geschriebenem Code falsche Sicherheit.

## Consequences

- Tests und Simulator brauchen nie Kamera oder Netz; der
  Build-/Test-Loop für Agenten (`xcodebuild`) bleibt CI-tauglich
  (Details im Ticket „Grilling: Projektgerüst & Repo-Layout").
- Fixtures werden bewusst nicht automatisch erneuert; bei geänderten
  dm-Antworten ist ein manueller Refresh per curl-Skript nötig.
- Die Schicht-Checkliste ist Teil jeder Ticket-Resolution; der
  treibende Agent fasst bei jeder Lieferung in Klartext zusammen,
  was die Tests beweisen und wie rote Ausgabe zu lesen ist.
