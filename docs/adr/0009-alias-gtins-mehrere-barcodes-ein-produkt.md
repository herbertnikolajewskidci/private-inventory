# Alias-GTINs: mehrere Barcodes → ein Produkt

Dasselbe physische Produkt kann mehrere GTINs tragen: Händler
nummerieren Eigenmarken-Linien neu (Relisting/Neuformulierung), die
alte Verpackung bleibt im Haushalt (realer Fall Session 11: Balea Men
„Golden Intense", gescannte GTIN `4066447599992` vs. aktuelle
`4070765015133`). Entscheidung: Ein `Product` behält seine Primär-GTIN
(ADR-0003-Identität bleibt unangetastet); eine neue Tabelle
`gtin_aliases` mappt weitere GTINs auf dieselbe Produkt-ID (gtin
unique, FK auf product). `fetchProduct(gtin:)` schlägt zuerst in
`products`, dann in `gtin_aliases` nach — ein einziger Aufruf, der
Aufrufer (`ScanSession` Pfad 1, Queue-Run Pfad 1) kennt keinen
Unterschied. Die Alias-Anlage erfolgt ausschließlich im
Foto-/Manuell-Bestätigungs-Moment (Ticket #24, D4a/D5a): Produkt unter
der Kandidaten-GTIN create-or-reuse + Alias für die gescannte GTIN +
Buchen/Löschen aller offenen Queue-Zeilen derselben GTIN in einem
Schritt; ein separater Alias-Verwaltungs-Screen bleibt out of scope
v1. Produkte aus Kandidaten-Bestätigung haben `source = manuell` (D8a)
— die GTIN-Bindung ist die kuratierte Wahrheit des Nutzers, nicht
eine App-Auflösung.

## Considered Options

- Produkt doppelt anlegen (eines pro GTIN): verworfen — derselbe
  physische Artikel erscheint zweimal in Bestand und
  „Haben wir noch?"-Suche; verfälscht die Kernfrage der App.
- Alias über den Katalogcache (positiver Cache-Eintrag für die alte
  GTIN): verworfen — TTL-befristet, vermischt kuratierte Wahrheit mit
  externen Quellendaten (ADR-0002/0008-Trennung) und kollidiert mit
  dem Negativ-Cache-Vertrag.
- Bestehendes Produkt auf die alte GTIN „umbenennen": verworfen —
  invertiert das Problem, dann wäre die aktuelle GTIN unmapped.

## Consequences

- Migration `0005_gtin_aliases` (UUID-Text-Keys, sync-tauglich
  ADR-0005); `createProduct` wirft `duplicateGTIN` auch gegen
  belegte Aliasse; `createGTINAlias(gtin:productID:)` validiert das
  Eltern-Produkt selbst (FKs aus in Release, ADR-0005).
- Alias ist lokal-persistent, ohne Netz und ohne TTL — ein Scan der
  alten GTIN bucht für immer bei demselben Produkt.
- Foto-/Manuell-Auflösung schreibt nichts in den Katalogcache
  (D7a): das kuratierte Produkt lebt nur lokal (ADR-0008 Pfad 1).
- Restfall (bewusst out of scope, D3-Grilling): wer **nur** manuell
  anlegt, bekommt das Produkt unter der gescannten GTIN; listet der
  Katalog diese GTIN später, entsteht ein zweites Produkt. Kein
  Auto-Merge in v1 (Bestands-Konsolidierung wäre eigenes Design);
  dokumentiert im Backlog-Pool der Map (#1, „Not yet specified"),
  Korrektur-Weg über Inventur.
