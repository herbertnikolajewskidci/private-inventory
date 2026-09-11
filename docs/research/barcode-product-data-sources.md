# Produktdatenquellen für Barcode-Lookup (EAN/GTIN) — dm-Drogerieprodukte

Recherche-Stand: 2026-09-11. Alle Endpunkte wurden an diesem Tag mit
`curl` live getestet (jeweils wenige Einzelrequests). Kernfrage: Wie kann
per EAN/GTIN ein Produktname (ideal: Marke, Bild, Kategorie) für deutsche
Drogerieprodukte aufgelöst werden — kostenlos und ohne API-Key?

## TL;DR

- Es existiert eine **offizielle dm-Schnittstelle** (MCP-Server
  `https://mcp.dm.de/mcp`), deren Tool `getProductDetails` GTINs direkt
  annimmt und Name, Marke, Bild, Beschreibung und Inhaltsstoffe liefert —
  ohne Auth, ohne Key. Quelle: <https://mcp.dm.de/>
- Zusätzlich funktioniert die **inoffizielle Such-API des dm-Onlineshops**
  (`product-search.services.dmtech.com`) mit einer GTIN als Suchbegriff —
  ohne Auth. Die alten direkten GTIN-REST-Endpunkte unter `products.dm.de`
  sind dagegen **tot (HTTP 404)** — das erklärt die bisher gescheiterten
  Versuche.
- OpenBeautyFacts/OpenFoodFacts sind per Barcode abfragbar (ODbL), decken
  aber das aktuelle dm-Sortiment faktisch nicht ab (Stichprobe: 0/5 Treffer).
- Alle generischen GTIN-Datenbanken (GS1, ean-search.org, opengtindb,
  Go-UPC, BarcodeLookup) sind entweder kostenpflichtig oder ohne
  Registrierung/Spende nicht programmatisch nutzbar.

## 1. dm-interne APIs

### 1.1 Offizieller dm MCP-Server (Primärquelle)

dm-drogerie markt betreibt einen offiziellen, öffentlich dokumentierten
MCP-Server (Model Context Protocol, streamable HTTP). Die Landingpage
nennt die Funktionen "Product Search", "Product Details",
"Store Availability" und "Store Search" und dokumentiert die Integration.

- URL: `https://mcp.dm.de/mcp` — Quelle: <https://mcp.dm.de/>
- Kein API-Key, keine Auth; Integration-Beispiele für Claude Code,
  Claude Desktop, VS Code, Cursor auf derselben Seite.

Live-Test (2026-09-11, JSON-RPC `tools/list` nach `initialize`-Handshake)
lieferte fünf Tools:

| Tool | Relevanz für Barcode-Lookup |
| --- | --- |
| `getProductDetails` | Nimmt `gtins` (8–14 Ziffern) oder `dans` direkt |
| `searchProducts` | Freitext-/semantische Suche, liefert u. a. GTIN |
| `getStoreAvailability` | Filialbestand per DAN (nicht nötig) |
| `findNearbyStores` | Filialsuche (nicht nötig) |
| `renderProductTiles` | UI-Kacheln per GTIN/DAN |

Live-Test `getProductDetails` mit der echten GTIN `4066447966008`
(Balea med Shampoo Ultra Sensitive) lieferte u. a.: DAN `1569035`,
Produktname, Marke "Balea med", Produkt-URL, Bild-URL auf
`products.dm-static.com`, Beschreibung, Inhaltsstoffe, Produkt-Features.
Unbekannte GTIN `9999999999999` → `found=false`,
`errorMessage="Product not found"`. (Eigener curl-Test gegen
<https://mcp.dm.de/mcp>.)

Dokumentierte Rate-Limits oder Nutzungsbedingungen für den MCP-Server:
auf <https://mcp.dm.de/> keine angegeben. Der Server verlangt pro Session
einen `initialize`-Handshake mit `Mcp-Session-Id` (Standard-MCP).

### 1.2 Inoffizielle HTTP-API des dm-Shops (Backend von dm.de/App)

Die folgenden Endpunkte stammen aus GitHub-Projekten, die sie im echten
Betrieb nutzen, und wurden einzeln per curl verifiziert.

**Produktsuche (funktioniert, auch per GTIN):**

```text
https://product-search.services.dmtech.com/de/search/crawl
  ?query={Suchbegriff-oder-GTIN}&pageSize=5&currentPage=0&type=search-static
```

- Test mit `query=4066447966008` lieferte genau das Produkt mit dieser
  GTIN inkl. `gtin`, `dan`, `brandName`, `title`, Preis und Bild-URLs
  (`tileData.images[].tileSrc` auf `products.dm-static.com`).
- Test mit unbekannter GTIN `9999999999999` → HTTP 200,
  `{"products":[],"count":0,...}` (sauberes Leerergebnis).
- Response-Header: `cache-control: public, max-age=345600` (4 Tage
  cachebar), keine Rate-Limit-Header beobachtet.
- Produktiv genutzt u. a. vom Preisvergleich hlidac-shopu:
  <https://github.com/topmonks/hlidac-shopu/blob/master/actors/dm-daily/main.js>
  (Funktion `makeListingUrl` baut exakt diesen crawl-Endpunkt).

**Produktdetail per dm-Artikelnummer (DAN) — funktioniert:**

```text
https://products.dm.de/product/products/detail/DE/dan/{dan}
https://products.dm.de/product/products/tiles/DE/dans/{dan}
```

- Test mit DAN `1569035`: Detail-Endpunkt liefert Marke, Breadcrumbs
  (Kategorien), Beschreibung, GTIN im Fließtext; Tiles-Endpunkt liefert
  `gtin`, `brand`, Bilder. Beide ohne Auth.
- Nutzung in freiem Code, dort ausdrücklich mit "kein Auth" kommentiert:
  <https://github.com/klotzbrocken/simplebanking/blob/main/Sources/simplebanking/DMService.swift>

**Tote Endpunkte (HTTP 404, auch mit echter GTIN getestet):**

```text
https://products.dm.de/product/de/products/gtins/{gtin}?view=details
https://products.dm.de/product/DE/products/detail/gtin/{gtin}
https://products.dm.de/product/de/search?productQuery=...
```

- Alle drei antworten mit Spring-Boot-404 (`"status":404,"error":"Not
  Found"`) — sowohl mit echter als auch mit unbekannter GTIN. Diese
  Pfade werden in älteren Projekten verwendet, z. B.
  <https://github.com/Jugendhackt/friendlyshampoo/blob/main/scraper.py>
  und <https://github.com/HenningLanghorst/toiletpaper-dm-bot/blob/main/src/main/kotlin/de/henninglanghorst/dm/DmApi.kt>.
  Befund: Die früher dokumentierten Direkt-GTIN-Endpunkte wurden
  abgeschaltet; GTIN-Auflösung läuft jetzt über die Suche (1.2) oder
  den MCP (1.1).

**Vollkatalog-Sitemap (funktioniert):**

```text
https://products.dm.de/productfeed/DE/sitemap.xml
```

- Liefert XML-URL-Liste aller dm.de-Produktseiten (mit `lastmod`).
  Genutzt von <https://github.com/steffkes/dm-products/blob/main/spider.py>.
  Für Einzel-Lookup irrelevant, aber als lokaler Index/Dump denkbar.

**Bild-CDN:** `products.dm-static.com` liefert Produktbilder ohne Auth
(Test: HTTP 200, 21 kB JPEG-äquivalent). Die Bild-URLs stecken bereits
in den Such-/Detail-Responses.

**ToS-/Lizenz-Risiko:** Die Daten sind nicht lizenziert; Nutzung der
inoffiziellen Endpunkte ist rechtlich eine Grauzone. Indizien:
`https://www.dm.de/robots.txt` sperrt nur Website-Pfade (`/search`,
`/cart` u. a.), nicht die API-Hosts; `https://products.dm.de/robots.txt`
existiert nicht (404). Der lange `cache-control`-Header der Such-API
signalisiert, dass Caching erwünscht ist. Für eine private App mit
geringem Volumen und lokalem Cache ist das Risiko niedrig, aber nicht
null — der offizielle MCP (1.1) entzieht sich dieser Grauzone.

## 2. OpenBeautyFacts / OpenFoodFacts / OpenProductsFacts

Gleiche Software (Product Opener), gleiche API-Form, getrennte
Datenbanken: Kosmetik (OBF), Lebensmittel (OFF), alles andere (OPF).

**API (Barcode-Lookup, kein Auth):**

```text
https://world.openbeautyfacts.org/api/v2/product/{barcode}.json
https://world.openfoodfacts.org/api/v2/product/{barcode}.json
https://world.openproductsfacts.org/api/v2/product/{barcode}.json
```

- Laut OBF-Datenseite ausdrücklich für Produktivnutzung freigegeben,
  solange "1 API call = 1 real scan by a user"; Bulk-Zugriff nur über
  die täglichen Exporte. Quelle: <https://world.openbeautyfacts.org/data>
- Rate-Limits (OFF-API-Doku, gleiche Infrastruktur): 15 req/min/IP für
  Produkt-Reads, 10 req/min/IP für Suche; zusätzlich globale Limits
  (HTTP 503). Custom User-Agent wird verlangt, Auth nur für Writes.
  Quelle: <https://openfoodfacts.github.io/openfoodfacts-server/api/>
- Lizenz: Datenbank ODbL, Inhalte DbCL, Produktbilder CC BY-SA 3.0.
  Quelle: <https://world.openbeautyfacts.org/data>

**Reale Abdeckung für dm-Produkte (Stichprobe, 2026-09-11):**

| GTIN | Produkt (laut dm) | OBF | OFF | OPF |
| --- | --- | --- | --- | --- |
| 4066447966008 | Balea med Shampoo | nein | nein | nein |
| 4066447989250 | Balea Duschgel | nein | — | — |
| 4066447965636 | Balea Duschgel | nein | — | — |
| 4066447965452 | Balea Duschgel | nein | — | — |
| 4066447725537 | dmBio Haferdrink | nein | nein | — |

("nein" = `status:0, "product not found"` im Live-Test.)

- OBF enthält insgesamt nur 471 Produkte der Marke Balea
  (Such-Count via `https://world.openbeautyfacts.org/cgi/search.pl?search_terms=balea&json=1`).
- Befund: Für aktuelle dm-Eigenmarken praktisch keine Abdeckung;
  als Fallback für Markenprodukte/Lebensmittel denkbar, nicht als
  Primärquelle. Fehlende Produkte können nutzerseitig per Foto
  beigesteuert werden (OBF-/OFF-App-Flow).

## 3. Sonstige GTIN-Datenbanken

| Dienst | Programmatisch kostenlos? | Befund | Quelle |
| --- | --- | --- | --- |
| GS1 "Verified by GS1" | Nein | Nur Web-Suche; API (GS1 UK "GTIN Check") nur für zahlende GS1-Partner; GS1 US API ist kostenpflichtiges Add-on | <https://www.gs1-germany.de/en/service-description/>, <https://www.gs1uk.org/standards-services/data-services/gtin-check-api>, <https://www.gs1us.org/tools/gs1-company-database-gepir> |
| ean-search.org | Nein | API nur mit Account; Trial 100 Queries/Monat (1. Monat 1 €, danach 9 €/Monat), Pro 5.000/Monat für 19 €/Monat | <https://www.ean-search.org/ean-database-api.html> |
| opengtindb.org | Nein | API braucht `queryid`; privat nur nach Spende ≥ 35 € (500 Queries/Tag, gedrosselt), kommerziell ab ~190 €/6 Monate. Test ohne `queryid`: `error=5` (access limit) | <https://opengtindb.org/api.php>, <https://opengtindb.org/userid.php> |
| Go-UPC | Nein | API-Key Pflicht; günstigster Plan 74,95 $/Monat (5.000 Lookups); Trial-Key nur auf Anfrage | <https://go-upc.com/plans/api>, <https://go-upc.com/docs> |
| BarcodeLookup | Nein | Ab 99 $/Monat (5.000 Calls) | <https://www.barcodelookup.com/api> |
| upcitemdb.com | Eingeschränkt | Trial-Endpunkt ohne Key erreichbar, aber Balea-Test-GTIN nicht gefunden (leere Antwort); starke Limits, US-Fokus | <https://www.upcitemdb.com/api/explorer> (Live-Test) |
| barcode.monster | Nein | `/api/` liefert 404; nur Website-Suche, keine nutzbare API (Live-Test) | <https://barcode.monster/> |
| OKFN "Open Product Data" | Nein | Historisches Projekt aus der GEPIR-Ära; GEPIR von GS1 abgeschaltet und durch "Verified by GS1" ersetzt | <https://product.okfn.org/gs1-data-resources/index.html>, <https://ref.gs1.org/architecture/system-architecture/> |

## 4. Empfehlung für den Flow "scannen → extern auflösen → lokal cachen"

1. **Primär: dm MCP `getProductDetails` mit der gescannten GTIN.**
   Offiziell, ohne Auth, liefert Name/Marke/Bild/Beschreibung direkt per
   GTIN. Einzige Quelle ohne Grauzonen-Risiko. MCP ist streamable HTTP —
   in einer eigenen App trivial per HTTP-Client anzubinden (initialize →
   tools/call), kein MCP-Framework nötig.
2. **Alternativ/Redundanz: dm-Such-API `…/de/search/crawl?query={gtin}`.**
   Gleiche Daten, schlichter REST-GET, 4 Tage HTTP-cachebar. Inoffiziell;
   bei Änderung durch dm auf den MCP ausweichen. Beide dm-Wege teilen,
   dass Nicht-dm-Produkte leer ausgehen — dann:
3. **Fallback-Kette für Nicht-dm-Produkte:** OpenBeautyFacts →
   OpenFoodFacts → OpenProductsFacts (je ein GET, ODbL-Attribution
   beachten, User-Agent setzen, 15 req/min einhalten). Erwartbare
   Trefferquote bei dm-Eigenmarken: gering (siehe Stichprobe).
4. **Lokaler Cache ist Pflicht, nicht Option:** Jede aufgelöste GTIN
   einmalig speichern (Name, Marke, Bild-URL, Quelle, Zeitstempel).
   OBF erlaubt API-Nutzung nur "1 call = 1 real scan"; dm signalisiert
   Cache-Freundlichkeit über lange `cache-control`-Header. Ein
   negativer Cache (GTIN → "nicht gefunden", mit TTL) verhindert
   Repeat-Lookups bei Aussortiertem.
5. **Nicht einplanen:** GS1, ean-search.org, opengtindb, Go-UPC,
   BarcodeLookup — alle kostenpflichtig oder registrierungs-/spenden-
   pflichtig und damit für eine private App ohne Mehrwert gegenüber
   den dm-Quellen.

**Antwort auf die Kernfrage:** Ja, eine brauchbare dm-EAN-Quelle
existiert — sogar zwei: der offizielle dm MCP-Server (GTIN-Direktabfrage)
und die inoffizielle dm-Such-API (GTIN als Query). Die alten
Direkt-GTIN-REST-Endpunkte unter `products.dm.de` sind abgeschaltet
(404), was die früheren erfolglosen Versuche erklärt.
