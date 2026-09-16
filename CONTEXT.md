# Private Inventory

Private Inventar-App für den Haushalt: Vorräte per Barcode-Scan
erfassen, jederzeit sehen, was wo liegt, und Doppelkäufe vermeiden.

## Language

Identifier im Code sind englisch; die _Code_-Angabe je Eintrag
ist kanonisch (ADR-0007). UI-Texte sind deutsch/englisch
(String Catalog).

**Produkt**:
Ein physischer Artikel im Haushalt, eindeutig identifiziert durch
seine GTIN.
_Avoid_: Artikel, Item, Ware
_Code_: `Product`

**GTIN**:
Die auf der Verpackung gedruckte Strichcode-Nummer (EAN); fachlicher
Schlüssel eines Produkts.
_Avoid_: QR-Code, Strichcode (im Code), Barcode (im Code)
_Code_: `GTIN`

**Standort**:
Frei definierbarer Lagerort eines Bestands (Defaults: Keller,
Vorratsschrank).
_Avoid_: Raum, Lager, Place
_Code_: `Location`

**Bestand**:
Die Menge eines Produkts an einem bestimmten Standort.
_Avoid_: Stock, InventoryItem
_Code_: `StockLevel`

**Einbuchen**:
Die Menge eines Produkts am aktuellen Standort um eins pro Scan
erhöhen (Supermarkt-Kassen-Prinzip).
_Avoid_: Hinzufügen, Einchecken
_Code_: `scanIn()`

**Scan-Session**:
Der immer-an-Erfassungs-Kontext im Scan-Tab: der Sitzungs-Standort plus
der Einstiegspunkt, der jeden Scan still einbucht (kein Start/Ende, kein
Standort-Dialog pro Scan).
_Avoid_: Scan-Flow, Scan-Vorgang
_Code_: `ScanSession`

**Sitzungs-Standort**:
Der Standort, an dem die Scan-Session einbucht; bewusst gewählt,
über App-Starts hinweg erhalten (zuletzt genutzt, Fallback Keller),
nie pro Scan.
_Avoid_: aktiver Standort, aktueller Lagerort
_Code_: `sessionLocationID`

**Entnehmen**:
Die Menge eines Produkts an einem Standort per Tap/Swipe reduzieren
(Verbrauch, kein Scan-Zwang).
_Avoid_: Ausbuchen, Löschen
_Code_: `withdraw()`

**Verschieben**:
Eine Menge eines Produkts von einem Standort an einen anderen
übertragen.
_Avoid_: Umlagern, Move
_Code_: `transfer()`

**Ungelöster Scan**:
Eine gescannte GTIN ohne lokalen oder externen Treffer; zählt sofort
als Bestand und wird bei Netzempfang automatisch nachaufgelöst.
_Avoid_: Pending Item, unbekanntes Produkt
_Code_: `UnresolvedScan`

**Katalogcache**:
Der lokale, persistente Speicher extern aufgelöster Produktdaten,
inklusive Negativ-Einträgen für GTINs ohne Treffer.
_Avoid_: Produktdatenbank, API-Cache
_Code_: `CatalogCache`

**Foto-Erkennung**:
Die Erfassung eines Produkts per Foto als Fallback, wenn die GTIN
nirgends auflösbar ist (OCR + Katalog-Match, kein VLM).
_Avoid_: KI-Scan
_Code_: `PhotoRecognition`

**Inventur**:
Der manuelle Korrekturdurchlauf, der App-Bestand und Realität wieder
angleicht (Gegenmittel gegen Bestandsdrift).
_Avoid_: Stocktake, Zählung
_Code_: `InventoryCount`
