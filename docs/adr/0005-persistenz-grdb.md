# Persistenz: GRDB statt SwiftData

Das Datenmodell (ADR-0003) braucht einen lokalen Store; ADR-0001 hält
die read-only-Freigabe für eine zweite Person (CloudKit `CKShare`) auf
der Roadmap. Entscheidung: **GRDB** (SQLite) mit UUID-Text-Primary-Keys
und `DatabaseMigrator`; die Persistenz bleibt hinter einem
Repository-Protokoll. Beleg: `docs/research/persistenz-swiftdata-vs-grdb.md`
(Ticket #3).

Warum: SwiftData kann die geplante read-only-Freigabe über die
öffentliche API nicht liefern — kein shared-Database-Scope in
`ModelConfiguration`, keine Brücke von Model-Instanzen zu
`CKRecord`-IDs. Zusätzlich würden die CloudKit-Constraints (keine
Unique-Constraints, Default-Werte/Optionals, additive-only
Production-Schema) das lokale Modell ab Tag 1 binden — und sie fallen
erst zur Laufzeit auf, ein konkretes Risiko bei KI-generiertem Code.
GRDB hält das lokale Schema frei (Unique auf `Produkt.gtin`, FTS5 für
die Katalogsuche); die Constraints treffen erst die spätere
CKRecord-Mapping-Schicht.

## Considered Options

- SwiftData: verworfen — kein `CKShare`-Pfad über die öffentliche API
  (Stand 2026-09-11, siehe Research-Dokument). Wird neu bewertet, falls
  die read-only-Freigabe aus der Roadmap fällt.

## Consequences

- UUID-Text-Primary-Keys überall ab Tag 1 (ADR-0003-konform);
  `CKRecord.recordName` wird später gleich der lokalen UUID.
- `Produkt.gtin` bekommt ein lokales Unique-Constraint; Deduplizierung
  bleibt nach dem Sync App-Aufgabe (CloudKit erzwingt Uniqueness
  nicht).
- Foreign Keys in Test-Builds aktiv, in Produktion deaktiviert
  (CloudKit liefert Records in beliebiger Reihenfolge).
- Spätere Sync-Phasen: `CKSyncEngine` für die private DB, dann
  `CKShare` mit `publicPermission = .readOnly` plus zweiter
  `CKSyncEngine`-Instanz für die shared DB (Phasenplan im
  Research-Dokument, Abschnitt 6.2).
