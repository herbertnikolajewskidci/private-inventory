# Scan-Session: immer-an-Modell, optimistisches Einbuchen über die Queue

Die Scan-Session ist immer an: keine Session-Entität mit Start/Ende,
kein expliziter Session-Schritt. Der Scan-Tab ist dauerhaft aktiv,
der Sitzungs-Standort ist immer gesetzt. Der Typ `ScanSession` in
`Core/Inventory/` (framework-frei, ADR-0007) hält den
`sessionLocationID` und den Scan-Einstiegspunkt und hängt nur an
den Protokollen `InventoryRepository` und `CatalogLookup`. Der
Sitzungs-Standort wird bewusst im Scan-Tab gewählt (Dropdown), vor
und während der Session änderbar, nie pro Scan (ADR-0003). Er wird
als zuletzt genutzter Standort persistiert — als Präferenz in der
App/Feature-Ebene, nicht in GRDB. Einheitliche Fallback-Regel: kein
gültiger gespeicherter Wert (Erststart oder gelöschter Standort) →
der geseedete Default „Keller" (erster geseedeter Default der
Migration `0002_seed_default_locations`).

Jeder Scan bucht, ohne je auf das Netzwerk zu warten: (1) Ein
lokales Produkt unter der GTIN (z. B. manuell angelegt — die
kuratierte Wahrheit des Nutzers) schlägt den externen Katalogcache →
`scanIn` am Sitzungs-Standort. (2) Ein Cache-Treffer (CatalogLookup,
cache-first) → create-or-reuse plus `scanIn` am Sitzungs-Standort.
(3) Kein Treffer → sofort `recordUnresolvedScan` (eigene Queue-Zeile,
Menge 1) und der Background-Queue-Run `resolvePendingScans()` wird
getriggert (Trigger ①). Sowohl ein sauberer Miss (nil) als auch ein
geworfener Lookup-Fehler buchen in die Queue: der Scan-Flow bricht
nie, kein Fehler-Dialog (ADR-0003). Wiederholte Scans derselben
ungelösten GTIN bleiben separate Queue-Zeilen; Aggregation ist eine
UI-Angelegenheit.

Trigger der Queue-Nachauflösung: ① sofort nach jedem
`recordUnresolvedScan` (Background-Task) und ② bei Netzempfang
(`NWPathMonitor`, App-Ebene — hier out of scope,
UI-Ticket). Beide rufen denselben idempotenten Orchestrierer auf.

## Considered Options

- Blockender Lookup im Scan-Flow (auf die Netz-Kette warten, dann
  Produkt- oder Ungelöst-Karte zeigen): verworfen — koppelt den
  Buchungs-Moment an das Netz, braucht einen Timeout-Regler und
  eine zusätzliche Zustandsmaschine.
- Explizite Session-Entität mit Start/Ende: verworfen —
  blockierender Zustand widerspricht „Scan-Flow bricht nie"; unter
  Button-Scan kein Nutzen.
- Aufsummierende Queue-Zeilen pro (GTIN, Standort): verworfen —
  zweite Schreib-Semantik, die nur einem Darstellungs-Wunsch dient.
- Sitzungs-Standort nur als Laufzeit-Zustand (ohne Persistenz):
  verworfen — die Keller-Nutzung würde bei jedem App-Start
  zurückgesetzt.

## Consequences

- Ein einheitlicher Buchungspfad pro Scan: Produkt oder Queue-Zeile,
  nichts dazwischen.
- Die Produkt-Bestätigung für frisch gescannte, tatsächlich lösbare
  dm-Produkte erscheint in der Home-Liste, wenn der Background-Run
  bucht — nicht auf der Scan-Karte.
- Das Scan-Flow-UI-Ticket (VisionKit, Scan-Tab, NWPathMonitor-
  Verdrahtung, Produktions-Injection der MCP → search → OBF/OFF-Kette)
  baut auf diesem Einstiegspunkt auf.
- `ScanOutcome` gibt der UI exakt zwei Karten-Varianten.
