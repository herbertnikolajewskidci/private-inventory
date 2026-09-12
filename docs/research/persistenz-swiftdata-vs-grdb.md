# Lokale Persistenz: SwiftData vs. GRDB

Recherche-Stand: 2026-09-11. Primärquellen: Apple Developer
Documentation, WWDC-Sessions (Transkripte), GRDB-GitHub-Repo
(README, DocC-Dokumentation, Issues/Discussions). Kernfrage aus
Ticket #3: Welcher Persistence-Layer für die private Inventar-App
(iOS 18, Single-User v1, weitgehend KI-generierter Code) — bei
offener Tür für späteres CloudKit-Sharing (read-only-Freigabe für
die zweite Person, ADR-0001) und sync-tauglichen IDs (ADR-0003)?

## TL;DR

- **Empfehlung: GRDB.** Es ist der einzige der beiden Kandidaten,
  der die geplante read-only-CKShare-Freigabe (ADR-0001) ohne
  späteren Neuaufbau der Persistenzschicht umsetzen kann:
  SwiftData hat keine öffentliche CKShare-API, keinen
  shared-Database-Scope in `ModelConfiguration` und keine Brücke
  von Model-Instanzen zu `CKRecord`-IDs.
- SwiftData punktet dagegen in v1: First-Party, deklarativ,
  CloudKit-Sync (private DB) per Konfigurationsflag, höchste
  API-Verbreitung in KI-Trainingsdaten. Würde die read-only-
  Freigabe aus dem Roadmap fallen, wäre SwiftData die einfachere
  Wahl.
- Die SwiftData+CloudKit-Constraints (keine Unique-Constraints,
  Default-Werte/Optionals, optionale Relationships,
  additive-only Production-Schema) sind Regeln von **CloudKit**,
  nicht von SwiftData — sie gelten also auch für jeden anderen
  Weg. Der Unterschied: GRDB hält sie aus dem lokalen SQLite-
  Schema heraus; sie treffen nur die (spätere) CKRecord-
  Mapping-Schicht.
- Migrations und Tests: GRDB klar im Vorteil (versionsierte,
  transaktionale, per `upTo:` testbare Migrations; SQLite-
  In-Memory-DBs). SwiftData hat seit iOS 17 `VersionedSchema` +
  `MigrationStage`, ist aber limitiert — und mit aktivem CloudKit
  zusätzlich an das additive-only Production-Schema gebunden.
- Konkreter CloudKit-Migrationspfad für die read-only-Freigabe
  (GRDB): UUID-Text-Primary-Keys ab Tag 1 (ADR-0003), später
  `CKSyncEngine` (Apple, iOS 17+) für private DB plus zweite
  Instanz für die shared DB, `CKShare` mit read-only-Link.
  Details in Abschnitt 6.2.

## 1. Kriterien (aus Ticket #3 / ADRs)

1. Sync-taugliche IDs für späteres CloudKit-Sharing (ADR-0003:
   keine lokalen Auto-Increment-Schlüssel)
2. Bekannte SwiftData+CloudKit-Constraints (Unique-Constraints,
   Default-Werte/Optional-Pflicht, u. a.)
3. Migrationsfreundlichkeit bei Schemaänderungen
4. Testbarkeit
5. Eignung für KI-generierten Code (API-Verbreitung in
   Trainingsdaten, Fehlerverzeihung)
6. Deployment-Target iOS 18

Zusätzlich gewichtet: die in ADR-0001 explizit festgehaltene
read-only-Freigabe für die zweite Person per CloudKit `CKShare`
("Bewusst nicht in v1, aber festgehalten").

## 2. SwiftData (Apple, First-Party)

### 2.1 Basis

- Framework seit iOS 17.0; kombiniert "Core Data's proven
  persistence technology" mit moderner Swift-Konkurrenz;
  deklarativ über Makros (`@Model`, `@Query`, `#Predicate`),
  "no external dependencies".
  Quelle: <https://developer.apple.com/documentation/swiftdata>
- iOS-18-Zusätze (WWDC24, Session 10137): `#Index`- und `#Unique`-
  Makro (Compound-Constraints, Upsert bei Kollision), History-
  API (`fetchHistory`), Custom Data Stores (`DataStore`-
  Protokoll, z. B. JSON-Store).
  Quellen: <https://developer.apple.com/videos/play/wwdc2024/10137/>,
  <https://developer.apple.com/documentation/updates/swiftdata>
- Der CloudKit-Sync läuft unter der Haube über Core Data:
  SwiftData nutzt `NSPersistentCloudKitContainer`.
  Quelle: <https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices>
- Aktivierung: iCloud- + Background-Modes-Capability (Remote
  Notifications) plus `ModelConfiguration(cloudKitDatabase:
  .private("iCloud..."))` oder automatische Container-Erkennung
  aus `Entitlements.plist`.
  Quelle: <https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices>

### 2.2 SwiftData + CloudKit: dokumentierte Constraints

Aus der SwiftData-Doku ("Syncing model data across a person's
devices"), Abschnitt "Define a CloudKit compatible schema":

<!-- markdownlint-disable MD013 -->
| SwiftData-Element | CloudKit-Limitation |
| --- | --- |
| `@Attribute(.unique)` | CloudKit kann Uniqueness nicht erzwingen, da der Sync konurrent und zu opportunistischen Zeitpunkten läuft |
| `@Relationship` | Alle Relationships müssen optional sein (keine atomare Verarbeitung garantiert); Inverse muss zuverlässig inferierbar oder explizit gesetzt sein; Delete-Rule `.deny` wird nicht unterstützt |
<!-- markdownlint-enable MD013 -->

Quelle: <https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices>

Aus der Core Data-Doku (gleiche Schicht, auf der SwiftData
läuft), "Creating a Core Data model for CloudKit":

- "Unique constraints aren't supported" (Entities)
- `transformable`- und external-storage-Attribute-Typen werden
  nicht unterstützt
- Alle Relationships müssen optional **und** ein Inverse haben;
  die "Deny"-Delete-Rule wird nicht unterstützt
- Entities einer Configuration dürfen keine Relationships zu
  Entities einer anderen Configuration haben
- Development-Schema: "You can't delete a record type or modify
  any existing attributes after you promote a development
  schema to production"
- Production: Record-Types und Felder sind danach "immutable
  and exist for all time" — nur neue Record-Types und Felder
  hinzufügen, keine Änderungen oder Deletions. App-Strategien
  laut Doku: neuer Store + neuer Container, inkrementelle
  Felder, Entity-Versionierung.
  Quelle: <https://developer.apple.com/documentation/coredata/creating-a-core-data-model-for-cloudkit>

Dazu die Laufzeit-Pflicht für Attribute: Nicht-Optionale
Attribute ohne Default-Wert scheitern beim Sync mit der
Apple-Fehlermeldung "CloudKit integration requires that all
attributes be optional, or have a default value set." (Fehler-
meldung, zitiert aus Apple-Developer-Forum-Threads; tritt als
Laufzeitfehler auf, nicht als Compile-Fehler.)
Quellen: <https://developer.apple.com/forums/thread/731375>,
<https://developer.apple.com/forums/thread/744491>

**Bedeutung für dieses Projekt:** Das lokale Modell muss von
Tag 1 cloudkit-kompatibel gestaltet werden (Default-Werte bei
allen Nicht-Optionalen, optionale Relationships, keine
Uniques). Diese Constraints sind dem Compiler nicht sichtbar —
sie fallen erst zur Laufzeit (beim Sync) auf. Für
KI-generierten Code, der nicht zeilenweise reviewed wird, ist
das ein konkretes Risiko.

### 2.3 CKShare: in SwiftData nicht verfügbar

Die read-only-Freigabe für die zweite Person erfordert
`CKShare` (Apple, seit iOS 10: "A specialized record type that
manages a collection of shared records").
Quelle: <https://developer.apple.com/documentation/cloudkit/ckshare>

Befunde zur SwiftData-Öffentlich-API (alle aus Apple-Doku):

1. Die SwiftData-Doku enthält keinen Sharing-Bereich; der
   "Model life cycle"-Bereich listet nur "Syncing model data
   across a person's devices".
   Quelle: <https://developer.apple.com/documentation/swiftdata>
2. `ModelConfiguration.CloudKitDatabase` bietet nur
   `.automatic`, `.private(_:)` und `.none` — keinen
   shared-Database-Scope. Die zugrunde liegende Core-
   Data-Schicht hat `databaseScope` ("public, private, or
   shared", seit iOS 15 für `.shared`), stellt SwiftData aber
   nicht exponiert.
   Quellen: <https://developer.apple.com/documentation/swiftdata/modelconfiguration/cloudkitdatabase-swift.struct>,
   <https://developer.apple.com/documentation/coredata/nspersistentcloudkitcontaineroptions/databaseScope-4c72t>
3. `PersistentIdentifier` exponiert nur `id`,
   `storeIdentifier`, `entityName`, `isTemporary` — keine
   `ckRecordID`. Ohne Record-ID kann kein `CKShare` auf ein
   SwiftData-Modell gelegt werden.
   Quelle: <https://developer.apple.com/documentation/swiftdata/persistentidentifier>

Zum Vergleich: Die Core Data-Schicht unterstützt Sharing
first-class — WWDC21-Session 10015 ("Build apps that share data
through CloudKit and Core Data") zeigt, wie
`NSPersistentCloudKitContainer` private und shared Datenbank in
zwei Stores spiegelt und per "Record Zone Sharing" (shared
`CKRecordZone`, identifiziert durch eine `CKShare`-Record, ohne
Root-Record) ganze Zonen freigibt. An diese APIs gelangt man
aus SwiftData nicht heraus (keine exponierte Container-Instanz).
Quellen: <https://developer.apple.com/videos/play/wwdc2021/10015/>,
<https://developer.apple.com/documentation/coredata/accepting-share-invitations-in-a-swiftui-app>

Community-Seite: Apple-Forum-Thread "CKShare-style user-to-user
sharing support in SwiftData" (Feature-Request, inkl.
Feedback-Assistant-Ticket FB22712510) — die Lücke ist bekannt
und offen.
Quelle: <https://developer.apple.com/forums/thread/825496>

**Folgerung:** Mit SwiftData ist die geplante read-only-
Freigabe über die öffentliche API nicht umsetzbar. Die
Alternativen (paralleler CKRecord-Spiegel neben SwiftData oder
private Core-Data-Brücke) bedeuten mehr Aufwand als der GRDB-
Weg (Abschnitt 6.2) oder sind für den App Store nicht tragbar.

### 2.4 Schema-Migration in SwiftData

- Seit iOS 17: `VersionedSchema`, `SchemaMigrationPlan`,
  `MigrationStage` mit `.lightweight(fromVersion:toVersion:)`
  (automatisch, nur eine begrenzte Änderungsmenge) und
  `.custom(fromVersion:toVersion:willMigrate:didMigrate:)`
  (manueller Fetch/Transform-Code).
  Quellen: <https://developer.apple.com/documentation/swiftdata/migrationstage>
  (Availability iOS 17.0),
  <https://developer.apple.com/documentation/swiftdata/schemamigrationplan>,
  <https://developer.apple.com/documentation/swiftdata/versionedschema>
- WWDC25 (iOS 26), Session 291 "SwiftData: Dive into inheritance
  and schema migration": zeigt den Plan-Workflow end zu ende
  (Versioned Schemas v2/v3/v4, custom- und lightweight-Stages);
  Model-Inheritance selbst ist neu in iOS 26.
  Quelle: <https://developer.apple.com/videos/play/wwdc2025/291/>
- Mit aktiviertem CloudKit gilt zusätzlich das additive-only
  Production-Schema (Abschnitt 2.2): nach der Promotion sind
  Attribute und Record-Types nicht mehr änderbar — deutlich
  restriktiver als jede lokale Migration.
  Quelle: <https://developer.apple.com/documentation/coredata/creating-a-core-data-model-for-cloudkit>

### 2.5 Testbarkeit

- In-Memory-Container: `ModelConfiguration(isStoredInMemoryOnly:
  true)` bzw. `.modelContainer(inMemory: true)`; WWDC24
  demonstriert das u. a. für Xcode-Previews.
  Quellen: <https://developer.apple.com/videos/play/wwdc2024/10137/>,
  <https://developer.apple.com/documentation/swiftdata/modelconfiguration>
- CloudKit-Tests: Die Doku kennt keine In-Memory-Variante mit
  CloudKit; der Sync-Setup verlangt iCloud- + Background-
  Modes-Capability und einen echten Container.
  Quelle: <https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices>

## 3. GRDB (groue/GRDB.swift)

### 3.1 Basis

- "A toolkit for SQLite databases, with a focus on application
  development", "proudly serving the community since 2015";
  8.6k Stars; Latest Release v7.11.1 (18. Juni 2026);
  Requirements: iOS 13.0+, SQLite 3.20.0+, Swift 6.1+ /
  Xcode 16.3+; MIT-Lizenz.
  Quelle: <https://github.com/groue/GRDB.swift>
- Kernfeatures laut README: SQL-Generierung (Codable-Records),
  Database Observation (`ValueObservation`), Robust Concurrency
  (WAL, `DatabaseQueue`/`DatabasePool`), Migrations, volle
  SQLite-Nutzung — inkl. FTS5 für Volltextsuche (relevant für
  die Produkt-Namensuche über den Katalogcache).
  Quelle: <https://github.com/groue/GRDB.swift>
- Sync-taugliche IDs: Primary Keys frei wählbar, im README-
  Beispiel `t.primaryKey("id", .text)` (UUID als Text) —
  direkt ADR-0003-konform; Unique-Constraints, Foreign Keys
  und Indexes auf SQLite-Ebene verfügbar.
  Quelle: <https://github.com/groue/GRDB.swift>

### 3.2 Migrations (Kernfeature)

Aus der offiziellen GRDB-Dokumentation (Migrations.md im
Repo):

- "Migrations allow you to evolve your database schema over
  time"; `DatabaseMigrator.registerMigration`,
  `migrate(dbQueue)`; "When a user upgrades your application,
  only non-applied migrations are run."
- "Each migration runs in a separate transaction" — wirft eine
  Migration einen Fehler, wird gerollt, Folgemigrations laufen
  nicht.
- "The memory of applied migrations is stored in the database
  itself (in a reserved table)."
- Migration auf bestimmte Version (nützlich für Tests):
  `migrate(dbQueue, upTo: "v2")`; Prüfungen
  `hasCompletedMigrations` / `hasBeenSuperseded`
  (u. a. für read-only-Extensionen und zu neue DBs).
- Dokumentiertes 7-Schritte-Verfahren zum Tabellen-Recreate
  (Standard-SQLite-Muster) für Änderungen, die SQLite nicht
  direkt unterstützt (z. B. NOT NULL nachträglich).
- Good Practice: "A good migration is a migration that is never
  modified once it has shipped"; Migrations sollen Strings
  statt App-Typen verwenden.

Quelle: <https://github.com/groue/GRDB.swift/blob/master/GRDB/Documentation.docc/Migrations.md>

### 3.3 Testbarkeit

- "Database queues support in-memory databases" (SQLite
  `:memory:`) — für deterministische Unit-Tests.
- `migrate(..., upTo:)` ermöglicht Migrationstests gegen
  historische Schema-Stände.
- Ökosystem: `GRDBSnapshotTesting` ("Test your database").
  Quelle: <https://github.com/groue/GRDB.swift>

### 3.4 CloudKit: kein Built-in, aber definierte Pfade

- GRDB hat keine CloudKit-Integration. Der Maintainer (groue)
  im Issue #385 (2018, geschlossen): keine eigenen CloudKit-
  Planungen, Verweis auf Community-Optionen (u. a. SyncKit).
  Quelle: <https://github.com/groue/GRDB.swift/issues/385>
- Diskussion #1569 "CloudKit synchronization options"
  (2024–2026) im GRDB-Repo dokumentiert den aktuellen Stand:
  - Optionen: Harmony (hohe Abstraktion, nur über deren
    Records-API schreiben), SQLiteChangesetSync (rohe SQLite-
    Changesets), minimalistisches CKSyncEngine-Setup
    (sobri909-Gist, `TransactionObserver`-basiert)
  - Maintainer zu Foreign Keys unter CloudKit: Apple-Engineer
    (WWDC22) empfehlen zwei Stores (CloudKit-Store + lokaler
    Validierungs-Store); er selbst würde "a schema without
    foreign keys" wählen
  - Etabliertes Community-Pattern: GRDB-`TransactionObserver` und
    `CKSyncEngine` (`syncEngine.state.add(pendingRecordZoneChanges:)`)
  - Neuere Optionen: pointfreeco/sqlite-data (v1.0.0,
    September 2025), PowerSync-Alpha für GRDB (Mai 2026)
  - Praktische Konsequenz aus dem Thread: FK-Constraints in
    der Produktion deaktivieren (CloudKit liefert Records in
    beliebiger Reihenfolge), Kaskaden per Triggers ersetzen
  Quelle: <https://github.com/groue/GRDB.swift/discussions/1569>

**Bedeutung:** Die CloudKit-Constraints (Unique, Reihungen,
additives Production-Schema) treffen bei GRDB nur auf die
CKRecord-Mapping-Schicht der Sync-Phase. Das lokale SQLite-
Schema bleibt vollständig frei: Unique auf `Produkt.gtin`, FKs
in Tests, FTS5 für die Suche.

## 4. Bausteine der späteren Sync-Phase (Apple, First-Party)

### 4.1 CKSyncEngine (iOS 17+)

- "An object that manages the synchronization of local and
  remote record data" — eine Engine, die Zone-Changes sendet
  und empfängt; das Mapping CKRecord <-> lokaler Store
  implementiert die App selbst (`CKSyncEngineDelegate`).
- Mehrere Instanzen pro Prozess möglich: "you may have one
  syncing a person's private database and another syncing
  their shared database" — der Sync der shared Datenbank ist
  ausdrücklich vorgesehen (notwendig für die read-only-
  Freigabe).
- Batch-Limit: 250 Records pro Request (saves plus deletes);
  der interne State muss von der App auf Disk persistiert
  werden; benötigt CloudKit- + Remote-Notifications-
  Entitlements.
  Quelle: <https://developer.apple.com/documentation/cloudkit/cksyncengine>
- Apple-Sample-Repo (Xcode 15 / iOS 17): "This project
  demonstrates using CKSyncEngine to sync data in an app",
  inkl. Test-Suite, die mehrere Geräte simuliert.
  Quelle: <https://github.com/apple/sample-cloudkit-sync-engine>

### 4.2 CKShare / read-only-Freigabe

- `CKShare` seit iOS 10. Sharing-Flow laut Apple-Doku
  ("Sharing CloudKit Data with Other iCloud Users"): Record
  auswählen, `CKShare` anlegen, `publicPermission` setzen
  (`.readOnly`/`.readWrite`, s. `CKShare.ParticipantPermission`),
  Share-Link versenden; die empfangende App verarbeitet die
  `CKShareMetadata` (im SwiftUI-App-Kontext über Scene-
  Delegate, eigener Apple-Artikel).
- Read-only ist explizit dokumentiert: "If the topic's
  'Anyone with this link can view' option is in an enabled
  state, participants have read-only permissions, and can't
  add a note under the topic."
  Quellen: <https://developer.apple.com/documentation/cloudkit/sharing-cloudkit-data-with-other-icloud-users>,
  <https://developer.apple.com/documentation/cloudkit/ckshare>

## 5. Bewertung nach Kriterien

<!-- markdownlint-disable MD013 -->
| Kriterium | SwiftData | GRDB |
| --- | --- | --- |
| Sync-taugliche IDs | OK: `PersistentIdentifier` ist systemseitig UUID-basiert (kein Auto-Increment); UUID-Business-Keys als normale Property | OK: UUID-Text-Primary-Key frei wählbar (`t.primaryKey("id", .text)`); `CKRecord.recordName` = UUID |
| CloudKit-Constraints | Binden das lokale Modell (Default-Werte, optionale Relationships, keine Uniques, transformable/external nicht erlaubt); Verstöße fallen erst zur Laufzeit auf | Betreffen nur die spätere CKRecord-Mapping-Schicht; lokales Schema frei (Unique/FK/FTS5 bleiben) |
| CKShare read-only | **Nicht über die öffentliche API** (kein Sharing-API, kein shared-Scope, keine Record-ID-Brücke; Core Data-Unterstützung aus SwiftData nicht erreichbar) | Machbar: `CKSyncEngine` (private + shared DB) + eigenes `CKShare` auf eine Zone/Root-Record; Apple-Sample vorhanden |
| Migrations | `VersionedSchema`/`MigrationStage` seit iOS 17; `.lightweight` nur begrenzte Änderungen, `.custom` = Handarbeit; mit CloudKit zusätzlich additive-only Production-Schema | First-Class: versionsiert, transaktional, per `upTo:` testbar, dokumentiertes Tabellen-Recreate-Verfahren |
| Testbarkeit | In-Memory-Container dokumentiert (WWDC24); In-Memory + CloudKit nicht dokumentiert | In-Memory-DB (SQLite-Standard), Migration-`upTo:`-Tests, `GRDBSnapshotTesting` |
| KI-generierter Code | Höchste Verbreitung in Trainingsdaten (First-Party seit 2023, SwiftUI-Standard); deklarativ/typsicher, Compiler fängt viel; API-Fläche wuchs 17→18→26 stark (neue Init, `CloudKitDatabase`-Struct, Makros) — Risiko veralteter Generierung; CloudKit-Constraints compile-time-invisible | Mature, stabile API (11 Jahre, v7.11.1, 8.6k Stars), systematische Doku; SQL ist in Trainingsdaten extrem vertreten, Fehler als descriptive Thrown Errors; zwei Paradigmen (Records + SQL) = größere Fehlerfläche; kein `@Query`-Äquivalent (Glue via `ValueObservation`) |
| iOS-18-Target | OK (iOS 17+) | OK (iOS 13+; Build mit Swift 6.1 / Xcode 16.3) |
<!-- markdownlint-enable MD013 -->

Hinweis: Die Zeile "KI-generierter Code" ist eine Einschätzung
auf Basis der zitierten Fakten (Alter, Verbreitung, Stabilität,
Dokumentation); eine objektive Messgröße existiert nicht.

## 6. Empfehlung

### 6.1 Entscheidung

**GRDB** — weil das entscheidende Kriterium die in ADR-0001
festgehaltene read-only-Freigabe für die zweite Person ist:

1. SwiftData kann dieses Feature über die öffentliche API nicht
   liefern (Abschnitt 2.3). Die Wahl SwiftData fixiert damit
   einen späteren Neuaufbau der Persistenzschicht, sobald die
   Freigabe umgesetzt werden soll.
2. GRDB hält die Tür zu allen ADR-Konsequenzen offen:
   CKShare-Pfad (Abschnitt 6.2), Schema-Evolution (lokale
   Migrations frei), CloudKit-Constraints nur in der
   Sync-Schicht.
3. Migrations und Tests sind bei GRDB explizit und testbar —
   relevant für ein Schema, das weiterwachsen wird
   (Katalogcache, Foto-Erkennung, Inventur).

Ehrliche Gegenposition: Für v1 (Single-Device, kein Sync-Code)
ist SwiftData der einfachere und für KI-Code vermutlich der
fehlerverzeihendere Start (höchste API-Verbreitung,
deklarativ, First-Party). Fällt die read-only-Freigabe aus dem
Roadmap, dreht sich die Empfehlung. Als Absicherung beider
Wege: Persistenz hinter einem Repository-Protokoll halten; das
Datenmodell (ADR-0003) ist mit UUID-IDs storage-agnostisch.

### 6.2 Konkreter CloudKit-Migrationspfad (GRDB)

**Phase 0 (v1, jetzt):**

1. GRDB + `DatabaseMigrator`; alle Tabellen mit
   `primaryKey("id", .text)` (UUID, ADR-0003).
2. `Produkt.gtin` als lokales Unique-Constraint (CloudKit
   erzwingt es später nicht — Dedup-Logik bleibt App-Aufgabe).
3. Foreign Keys in Test-Builds aktiv, in Produktion ohne
   (Begründung: CloudKit-Reihenfolge, Diskussion #1569);
   alternativ Zone-Reihenfolge per
   `CKSyncEngine.FetchChangesOptions.prioritizedZoneIDs` in
   Phase 1.
4. FTS5-Virtual-Table für die Produkt-Namensuche
   (Katalogcache, ADR-0002).
5. UI-Beobachtung über `ValueObservation` + Observable.

**Phase 1 (private-DB-Sync, optional, z. B. zwei eigene
Geräte):**

1. CKRecord-Mapping: `recordName` = lokaler UUID
   (deterministisch), Record-Types = Tabellen; Mapping in der
   `CKSyncEngineDelegate`-Implementierung (Pattern: Diskussion
   #1569, Basis: Apple-Sample).
2. `CKSyncEngine` für die private Datenbank; Entitlements:
   CloudKit + Remote Notifications; State-Persistierung;
   Sync-Tests wie im Apple-Sample (simulierte Geräte).

**Phase 2 (read-only-Freigabe für die zweite Person, CKShare):**

1. Freigabe-Zone anlegen (eigene `CKRecordZone` im
   Private-DB-Kontext, z. B. mit einer `InventoryRoot`-Record
   als Sammelstelle).
2. `CKShare` auf der Zone/Root-Record erzeugen mit
   `publicPermission = .readOnly` (read-only-Link, Abschnitt
   4.2); Link an die zweite Person (z. B. Messages).
3. App auf dem zweiten Gerät: Share akzeptieren
   (`CKShareMetadata` verarbeiten, vgl. Apple-Artikel
   "Sharing CloudKit Data..."); eigene `CKSyncEngine`-Instanz
   für die **shared**-Datenbank (offiziell unterstützt,
   Abschnitt 4.1) lädt die freigegebenen Records in eine
   lokale read-only GRDB-Datenbank.
4. UI zeigt den Shared-Bestand read-only; Schreibvorgänge
   bleiben auf dem Gerät der Person 1 (private Datenbank).

**Warum nicht SwiftData + manuellem CKRecord-Spiegel?** Ein
paralleler CloudKit-Schreibkanal neben SwiftData dupliciert
State und kostet mehr Aufwand als der direkte
GRDB+CKSyncEngine-Weg; eine private Core-Data-Brücke aus
SwiftData heraus ist für den App Store nicht tragbar.

## Quellen

- Apple: SwiftData (Doku-Index):
  <https://developer.apple.com/documentation/swiftdata>
- Apple: Syncing model data across a person's devices:
  <https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices>
- Apple: Creating a Core Data model for CloudKit:
  <https://developer.apple.com/documentation/coredata/creating-a-core-data-model-for-cloudkit>
- Apple: Reading CloudKit Records for Core Data:
  <https://developer.apple.com/documentation/coredata/reading-cloudkit-records-for-core-data>
- Apple: ModelConfiguration.CloudKitDatabase:
  <https://developer.apple.com/documentation/swiftdata/modelconfiguration/cloudkitdatabase-swift.struct>
- Apple: PersistentIdentifier:
  <https://developer.apple.com/documentation/swiftdata/persistentidentifier>
- Apple: NSPersistentCloudKitContainerOptions.databaseScope:
  <https://developer.apple.com/documentation/coredata/nspersistentcloudkitcontaineroptions/databaseScope-4c72t>
- Apple: MigrationStage:
  <https://developer.apple.com/documentation/swiftdata/migrationstage>
- Apple: SchemaMigrationPlan:
  <https://developer.apple.com/documentation/swiftdata/schemamigrationplan>
- Apple: VersionedSchema:
  <https://developer.apple.com/documentation/swiftdata/versionedschema>
- Apple: CKSyncEngine:
  <https://developer.apple.com/documentation/cloudkit/cksyncengine>
- Apple: CKShare:
  <https://developer.apple.com/documentation/cloudkit/ckshare>
- Apple: Sharing CloudKit Data with Other iCloud Users:
  <https://developer.apple.com/documentation/cloudkit/sharing-cloudkit-data-with-other-icloud-users>
- Apple: Accepting share invitations in a SwiftUI app:
  <https://developer.apple.com/documentation/coredata/accepting-share-invitations-in-a-swiftui-app>
- Apple: SwiftData updates:
  <https://developer.apple.com/documentation/updates/swiftdata>
- Apple: WWDC24 "What's new in SwiftData" (Session 10137):
  <https://developer.apple.com/videos/play/wwdc2024/10137/>
- Apple: WWDC25 "SwiftData: Dive into inheritance and schema
  migration" (Session 291):
  <https://developer.apple.com/videos/play/wwdc2025/291/>
- Apple: WWDC21 "Build apps that share data through CloudKit
  and Core Data" (Session 10015):
  <https://developer.apple.com/videos/play/wwdc2021/10015/>
- Apple: sample-cloudkit-sync-engine:
  <https://github.com/apple/sample-cloudkit-sync-engine>
- Apple Developer Forum: Disable automatic iCloud sync with
  SwiftData (Fehlermeldung Default-Werte):
  <https://developer.apple.com/forums/thread/731375>
- Apple Developer Forum: SwiftData with CloudKit failing to
  migrate schema (Fehlermeldung Default-Werte):
  <https://developer.apple.com/forums/thread/744491>
- Apple Developer Forum: CKShare-style user-to-user sharing
  support in SwiftData:
  <https://developer.apple.com/forums/thread/825496>
- GRDB: README/Repo:
  <https://github.com/groue/GRDB.swift>
- GRDB: Migrations-Dokumentation (DocC im Repo):
  <https://github.com/groue/GRDB.swift/blob/master/GRDB/Documentation.docc/Migrations.md>
- GRDB: Issue #385 "CloudKit integration":
  <https://github.com/groue/GRDB.swift/issues/385>
- GRDB: Discussion #1569 "CloudKit synchronization options":
  <https://github.com/groue/GRDB.swift/discussions/1569>
