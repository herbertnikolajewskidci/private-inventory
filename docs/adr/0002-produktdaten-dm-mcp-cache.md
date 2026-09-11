# Produktdaten: dm MCP primär, lokaler Katalogcache mit Negativ-Einträgen

GTIN-Auflösung über offizielle dm-Schnittstellen, danach aggressiv
lokal gecacht. Reihenfolge: dm MCP `getProductDetails` (offiziell,
ohne Auth, nimmt GTIN direkt) → dm Such-API (inoffiziell, GTIN als
Query, 4-Tage-Cache-Header) → OpenBeautyFacts/OpenFoodFacts (nur für
Nicht-dm-Produkte). Jede aufgelöste GTIN wird mit Quelle und
Zeitstempel im Katalogcache gespeichert; Nicht-Treffer landen im
Negativ-Cache. Beleg: `docs/research/barcode-product-data-sources.md`
(2026-09-11, alle Endpunkte live per curl verifiziert).

## Considered Options

- Alte Direkt-GTIN-Endpunkte unter `products.dm.de`: abgeschaltet
  (HTTP 404) — das war der Grund für die früher gescheiterten
  Versuche.
- Generische GTIN-Datenbanken (GS1, ean-search.org, opengtindb,
  Go-UPC, BarcodeLookup): kostenpflichtig oder registrierungs-/
  spendenpflichtig — verworfen.
- OpenBeautyFacts als Primärquelle: verworfen — praktisch keine
  Abdeckung aktueller dm-Eigenmarken (Stichprobe 0/5).

## Consequences

- Offline-first ist zwingend: unbekannte GTIN ohne Netz landet als
  Ungelöster Scan in der Queue (ADR-0003) und wird bei Empfang
  automatisch aufgelöst.
- OBF/OFF erlauben API-Nutzung nur im Stil "1 Call = 1 echter Scan";
  der lokale Cache ist damit Pflicht, nicht Option.
- Die inoffizielle Such-API ist rechtlich eine Grauzone; der
  offizielle MCP ist der saubere Primärweg.
