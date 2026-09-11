# Datenmodell: Produkt × Standort → Menge, plus Queue für Ungelöste Scans

Vier Entitäten: Produkt (GTIN als Schlüssel; Name, Marke, Bild-URL,
Quelle: mcp/search/obf/manuell), Standort (frei definierbar, Defaults
Keller + Vorratsschrank), Bestand (Produkt × Standort → Menge),
Ungelöster Scan (GTIN, Standort, Menge, Zeitpunkt). Einbuchen = +1 am
Sitzungs-Standort; Entnehmen = Mengen-Abzug per Tap/Swipe;
Verschieben = Mengen-Transfer zwischen zwei Beständen.

## Considered Options

- Fest verdrahtete Standorte (nur Keller/Vorratsschrank): verworfen —
  freie Standorte kosten nur eine Tabelle und ersparen eine spätere
  Migration.
- Scan-Zwang beim Entnehmen: verworfen — überlebt den Alltag nicht;
  stattdessen schneller Abzug per Tap/Swipe.

## Consequences

- IDs sind von Anfang an sync-tauglich (keine lokalen
  Auto-Increment-Schlüssel), damit späteres CloudKit-Sharing
  (ADR-0001) ohne Datenmigration möglich ist.
- Bestandsdrift (App ≠ Realität) wird bewusst akzeptiert und später
  per Inventur korrigiert — nicht über Erfassungs-Zwang.
- Scan am "falschen" Ort bucht still am Sitzungs-Standort und zeigt
  andere Standorte nur passiv an (kein Dialog im Scan-Flow).
