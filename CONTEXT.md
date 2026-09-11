# Private Inventory

Private Inventar-App für den Haushalt: Vorräte per Barcode-Scan
erfassen, jederzeit sehen, was wo liegt, und Doppelkäufe vermeiden.

## Language

**Produkt**:
Ein physischer Artikel im Haushalt, eindeutig identifiziert durch
seine GTIN.
_Avoid_: Artikel, Item, Ware

**GTIN**:
Die auf der Verpackung gedruckte Strichcode-Nummer (EAN); fachlicher
Schlüssel eines Produkts.
_Avoid_: QR-Code, Strichcode (im Code), Barcode (im Code)

**Standort**:
Frei definierbarer Lagerort eines Bestands (Defaults: Keller,
Vorratsschrank).
_Avoid_: Raum, Lager, Place

**Bestand**:
Die Menge eines Produkts an einem bestimmten Standort.
_Avoid_: Stock, InventoryItem

**Einbuchen**:
Die Menge eines Produkts am aktuellen Standort um eins pro Scan
erhöhen (Supermarkt-Kassen-Prinzip).
_Avoid_: Hinzufügen, Einchecken

**Entnehmen**:
Die Menge eines Produkts an einem Standort per Tap/Swipe reduzieren
(Verbrauch, kein Scan-Zwang).
_Avoid_: Ausbuchen, Löschen

**Verschieben**:
Eine Menge eines Produkts von einem Standort an einen anderen
übertragen.
_Avoid_: Umlagern, Move

**Ungelöster Scan**:
Eine gescannte GTIN ohne lokalen oder externen Treffer; zählt sofort
als Bestand und wird bei Netzempfang automatisch nachaufgelöst.
_Avoid_: Pending Item, unbekanntes Produkt

**Katalogcache**:
Der lokale, persistente Speicher extern aufgelöster Produktdaten,
inklusive Negativ-Einträgen für GTINs ohne Treffer.
_Avoid_: Produktdatenbank, API-Cache

**Foto-Erkennung**:
Die Erfassung eines Produkts per Foto als Fallback, wenn die GTIN
nirgends auflösbar ist (OCR + Katalog-Match, kein VLM).
_Avoid_: KI-Scan

**Inventur**:
Der manuelle Korrekturdurchlauf, der App-Bestand und Realität wieder
angleicht (Gegenmittel gegen Bestandsdrift).
_Avoid_: Stocktake, Zählung
