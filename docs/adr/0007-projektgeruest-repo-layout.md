# Projektgerüst: Monorepo app/, Xcode 26, Single-Target, CI ab Tag 1

Der Code wird weitgehend von KI-Agenten geschrieben; der Nutzer
(DevOps, kein iOS-Hintergrund, siehe AGENTS.md) braucht einen
Agent-tauglichen Build-/Test-Loop und eine Struktur, die ohne
Xcode-Kenntnis navigierbar ist. Entscheidungen (Ticket „Grilling:
Projektgerüst & Repo-Layout" (#7)):

## Ort & Projektdatei

- Monorepo: Code unter `app/` in diesem Repo, neben `docs/`, den
  ADRs und der Wayfinding-Map (Issues).
- Xcode 26 (App Store; lokal 26.6 — die Research-Angabe
  „Xcode 27“ aus Ticket #7 war falsch, Apple zählt seit 2025
  jahresbasiert). Exakte Version in `.xcode-version`
  festgeschrieben; CI asserted dagegen (Drift-Frühwarnung).
- File-system-synchronized groups (Xcode-16-Standard): das Projekt
  referenziert Ordner statt Einzeldateien — Agent legt Datei an =
  Datei ist im Build, keine pbxproj-Edits und keine
  Merge-Konflikt-Hölle.

## Identität & Plattform

- Projekt/Target/Scheme: `PrivateInventory`; Test-Target
  `PrivateInventoryTests`; Display-Name „Inventar".
- Bundle-ID `io.github.herbertnikolajewskidci.privateinventory`.
- Deployment-Target iOS 26.0 (beide Haushaltsgeräte auf iOS 26).
- Swift 6 Language Mode ab Tag 1 (Compiler als erster Reviewer
  für Agent-Code, Begründung bereits in ADR-0001).

## Struktur & Sprache

- Ein App-Target, interne Grenzen per Ordnerkonvention und
  Protokollen; `Core/` bleibt frei von Framework-Imports (das ist
  die Schicht, die die Tests tragen, ADR-0006). Ordner: `App/`,
  `Features/{Scan,Search,Stock}/`, `Core/{Inventory,Catalog}/`,
  `Persistence/`.
- Code-Identifier englisch; die kanonische Mapping-Tabelle
  (Glossar → Code-Begriff) lebt in CONTEXT.md. UI-Texte über
  String Catalog (`Localizable.xcstrings`), Locales `en` + `de`
  ab v1, keine hardcodierten Strings in SwiftUI-Views.
- Fixtures final unter `app/PrivateInventoryTests/Fixtures/`
  (löst den offenen ADR-0006-Verweis ein); Aufnahme per
  `scripts/record-fixtures.sh` (curl, manuell).

## Tooling & Agent-Loop

- GRDB via SPM `upToNextMajor`, `Package.resolved` im Repo.
- SwiftFormat + SwiftLint via Homebrew; `swiftformat .` vor jedem
  Commit (führt der Agent aus), Lint nur als CI-Check. Keine
  Xcode-Build-Phasen — die Agent-Loop-Zeit ist die knappe
  Ressource.
- `scripts/build.sh` + `scripts/test.sh` (bash,
  `set -euo pipefail`) wrappen `xcodebuild` mit fixem Scheme und
  Simulator-Destination (iPhone 17, neueste Runtime); Ausgabe über
  xcbeautify (kompakt, Token-sparend im Agent-Kontext),
  Result-Bundle unter `build/` für Fehlerdetails.

## CI & Repo-Hygiene

- `.github/workflows/ci.yml`, Trigger push/PR auf `main`:
  Job `lint` (macos-26: `swiftformat --lint`, `swiftlint`),
  Job `test` (macos-26: ruft dasselbe `scripts/test.sh` wie der
  Agent lokal — ein Loop, zwei Ausführer), Job `docs`
  (ubuntu-latest: markdownlint über alle `.md`). Kein Signing
  (`CODE_SIGNING_ALLOWED=NO`): CI bleibt unabhängig vom Ticket
  „Task: Apple-Developer-Account & Geräte-Signierung" (#8).
  Keine Matrix, kein Caching in v1.
- Branch-Präfix für Umsetzungs-Tickets: `feat/<ticket-slug>`
  (Familie komplett: `research/` · `prototype/` · `feat/`).
- LICENSE: MIT.

## Considered Options

- Eigenes Code-Repo: verworfen — trennt ADRs und Issues vom Code
  und verdoppelt den Tracker; ein Repo = eine Wahrheit.
- XcodeGen/Tuist (Projektdatei aus YAML generiert): verworfen —
  synchronisierte Ordner lösen das pbxproj-Problem ohne
  Zusatz-Tool und ohne Generierungsschritt im Agent-Loop.
- Lokale SPM-Packages pro Schicht (≈ npm-Workspaces): verworfen —
  die harten Grenzen (Repository-, Scanner-Protokoll) sind per
  ADR vereinbart und über Tests gegatekeeped; Split erst bei
  Compile-Zeit- oder Grenzverletzungs-Schmerz.
- Deployment-Target iOS 18: verworfen — keine Altgeräte im
  Haushalt; höheres Target spart `if #available`-Rauschen in
  Agent-Code.
- Deutsche Code-Identifier (Glossar direkt als Typnamen):
  verworfen — Nutzer-Entscheidung zugunsten durchgängig
  englischen Codes; Deutsch lebt in den UI-Texten (String
  Catalog en/de von Tag 1 statt nachgerüstet).
- Swift 5 Language Mode: verworfen — Strict-Mode fängt
  Agent-Fehler zur Compile-Zeit; ein späterer Retrofit wäre ein
  eigenes Migrationsprojekt.
- Lint/Format als Xcode-Build-Phase: verworfen — bremst jeden
  Agent-Loop.
- `just`/Makefile als Skript-Hülle: verworfen — ein Tool weniger.
- CI-Matrix und SPM-Caching: verworfen für v1 — Komplexität erst
  bei Schmerz.
- Exakter Versions-Pin für GRDB: verworfen — `upToNextMajor`
  plus committetes Lockfile reicht bei einer einzigen Dependency.

## Consequences

- Der Build-/Test-Loop läuft lokal und in CI über dasselbe
  Skript; Simulator-Tests brauchen weder Kamera, Netz noch
  Signing (ADR-0006-konform). CI blockt nicht auf Ticket #8;
  der Device-Deploy bleibt davon unberührt.
- CONTEXT.md führt kanonische englische Code-Begriffe (Code-Zeile
  je Glossar-Eintrag); neue Domänenbegriffe landen zuerst dort.
- Versions-Entscheidungen (Frameworks, Dependencies, Targets,
  Tools) werden vor Festschreibung per Research-Agent oder
  Context7 verifiziert — Konvention, festgehalten in AGENTS.md.
- Das eigentliche Scaffolding (Xcode-Projekt anlegen, Skripte
  schreiben, erster grüner Test) ist ein eigenes Task-Ticket und
  setzt die laufende Xcode-Installation voraus.
