# On-device Vision-LLMs auf iOS — Drogerieprodukt-Foto → Produktname

Recherche-Stand: 2026-09-11. Alle Primärquellen (Apple-Developer-Doku,
WWDC26-Sessions, HuggingFace-API, GitHub-API) wurden an diesem Tag per
`curl`/Fetch geprüft; Sekundärquellen (Community-Benchmarks) sind als
solche gekennzeichnet. Kernfrage: Kann eine private native iOS-App aus
einem Produktfoto (Drogerie) on device Produktname/Marke ablesen — mit
welchem Framework/Modell und welchen Limits (Größe, Lizenz, Hardware)?

## TL;DR

- **Ja, auf aktuellen iPhones (Apple-Intelligence-Generation, A17 Pro
  und neuer) realistisch** — über zwei Wege: (1) Apple Foundation
  Models: Bild-Input via `Attachment` erst seit **iOS 27.0** (WWDC26,
  Juni 2026), on device, ohne Modell-Download; (2) offene VLMs
  (0,5–3 B, 4-bit) via MLX Swift oder LiteRT-LM, Modell-Download
  (1,3–4,5 GB) am ersten Start.
- **Robuster Primärpfad bleibt Vision-OCR + Katalog-Matching:**
  `RecognizeTextRequest` (iOS 18+) liest Verpackungstext
  deterministisch; das Matching läuft gegen den dm-Katalog
  (siehe barcode-product-data-sources.md). VLMs ersetzen OCR nicht,
  sie fangen Fuzzy-Fälle (verformte/abgenutzte Etiketten, fremde
  Marken) auf.
- **Lizenz-Fallen bei den "offenen" VLMs:** Qwen2.5-VL-3B läuft
  unter der Qwen Research License (Nicht-Kommerziell-only), FastVLM
  unter der Apple ML Research License (Research-only). Auslieferbar
  sind Gemma 3n (Gemma Terms of Use), SmolVLM2 (Apache-2.0) und
  Gemma 4 (Apache-2.0).
- **GB-Modelle gehören nicht ins App-Bundle** (thinned-Bundle-Limit
  4 GB) → Download am ersten Start ist der Standard (MLXChatExample,
  FastVLM-Demo-App). ODR ist seit iOS 27 deprecated, Nachfolger:
  Background Assets.
- **Empfehlung (Kurzform):** Vision-OCR + Katalog als Kern,
  Foundation-Models-VLM (iOS 27) als Fuzzy-Zweitpfad, PCC als
  Server-Fallback ohne eigene Infrastruktur. Details in Abschnitt 5.

## 1. Apple Foundation Models framework (iOS 26+)

### 1.1 Basis: iOS 26.0+, im ersten Jahr text-only

Das Framework (Quelle:
<https://developer.apple.com/documentation/foundationmodels>) ist
seit **iOS 26.0** verfügbar (iPadOS/Mac Catalyst/macOS 26.0,
visionOS 26.0, watchOS 27.0) und erfordert ein
Apple-Intelligence-Gerät. Im ersten Jahr (WWDC25) war es text-only;
Bild-Unterstützung kam erst mit der WWDC26-Generation.

`SystemLanguageModel` (Quelle:
<https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel>)
ist das on-device Modell; Apple aktualisiert es in OS-Updates
regelmäßig. Laut Doku existieren drei Modellversionen, gebunden an
iOS 26.0–26.3, 26.4 und 27.0. Verfügbarkeit vor jeder Nutzung prüfen
via `model.availability` (`.available`,
`.unavailable(.deviceNotEligible)`, `.unavailable(.modelNotReady)`).

### 1.2 Bild-Input: seit WWDC26, also iOS 27.0+

Bild-Input in Prompts ist seit der WWDC26-Generation möglich.
WWDC26-Session 241 "What's new in the Foundation Models framework"
(Kapitel 3:21 "Vision: image understanding"):
<https://developer.apple.com/videos/play/wwdc26/241/>

- Doku-Artikel "Analyzing images with multimodal prompting" [1]:
  Bild + Text-Prompt, Beispiele u. a. "Identifying a list of items
  within a photo of a fridge to generate recipe ideas" — exakt die
  Klasse unserer Aufgabe (Produktliste aus Foto).
- `Attachment` ist als Struktur **iOS 27.0+** (Availability-Badge,
  Quelle:
  <https://developer.apple.com/documentation/foundationmodels/attachment>).
- Eingabetypen: UIImage, NSImage, CGImage, CIImage, CVPixelBuffer,
  Date-URL; beliebige Größe/Seitenverhältnis — größere Bilder
  kosten mehr Tokens und Latenz (Session 241, 3:52–4:19).
- Strukturierte Ausgabe per `@Generable` (Enum-Labels oder Structs)
  — direkt nutzbar für ein "name + brand + confidence"-Schema.
- Apple empfiehlt den Pattern: erst on device analysieren, bei
  Bedarf `PrivateCloudComputeLanguageModel` (Abschnitt 1.4).

### 1.3 Kontextgröße & Token-Budget

- Doku "Managing the context window" [2]: on-device Modell hat
  **4096 Tokens pro Session**; Überschuss wirft
  `LanguageModelError.contextSizeExceeded`, dann neue Session mit
  kondensiertem Transcript.
- Das WWDC26-Codebeispiel (Session 241, 2:46) zeigt `contextSize` =
  **8192** für das neue Modell — der Wert ist
  modellversionsabhängig; die APIs `model.contextSize` und
  `model.tokenCount(for:)` existieren seit iOS 26.4 (Session 241:
  "In iOS 26.4, we released new APIs for inspecting the model's
  context size and counting the tokens").
- Für Produktfotos reicht 4096–8192 Tokens, wenn Prompt schlank
  bleibt und die Ausgabe per `@Generable` auf wenige Felder
  begrenzt wird (Doku empfiehlt kurze Prompts, 3–5 Tools).

### 1.4 Private Cloud Compute (PCC)

`PrivateCloudComputeLanguageModel` (Session 241, Kapitel 4:20):
32.000-Token-Kontext mit Reasoning-Level, ohne API-Key/Account,
privat (Prompts werden nicht gespeichert, verifizierbar). Kostenlos
für Entwickler mit **unter 2 Mio. First-Time-Downloads**;
iCloud+-Abonnenten der Nutzer bekommen höhere tägliche Limits.
Entitlement `com.apple.developer.private-cloud-compute` nötig.
Damit ist PCC der Server-Fallback ohne eigene Infrastruktur
(Abschnitt 5.2, Punkt c).

### 1.5 Geräte-Voraussetzungen

Nur Apple-Intelligence-Geräte (Quelle:
<https://www.apple.com/apple-intelligence/>): iPhone 15 Pro/Pro Max
(A17 Pro) und iPhone-16-Generation (A18) bzw. neuer — praktisch
alles ab Herbst 2023. Ältere iPhones (A14/A15) sind für den
Foundation-Models-Pfad ausgeschlossen.

### 1.6 Vision-Tools in der Session (OCR/Barcode als Tool-Call)

WWDC26-Session 237 "What's new in image understanding":
<https://developer.apple.com/videos/play/wwdc2026/237/>

- `BarcodeReaderTool` und `OCRTool` aus dem Vision Framework lassen
  sich als Tools in eine `LanguageModelSession` geben; der OCRTool
  ist laut Session "good for helping models read really fine or
  dense text" und liest **30+ Sprachen**.
- Image-basierte Tool-Argumente: `ImageReference` — das Tool
  bekommt eine Referenz auf das Session-Bild, nicht das komplette
  Bild.
- Neue tap-to-segment API (`GenerateIterativeSegmentationRequest`):
  ein Produkt im Foto vor der LLM-Analyse ausgrenzen; das
  Segmentierungsmodell wird per `downloadAssets`/`assetStatus`
  geladen. Die Multimodal-Doku empfiehlt genau dieses
  Preprocessing ("isolating a region of interest").
- Vision kommt damit zusätzlich auf watchOS 27.

`RecognizeTextRequest` (Quelle:
<https://developer.apple.com/documentation/vision/recognizetextrequest>)
ist der reine OCR-Weg ohne LLM: **iOS 18.0+**, mit
`recognitionLanguages`, `recognitionLevel` (accurate/fast),
`customWords` (Marken-/Produktbegriffe als Vokabular ergänzen —
direkt nützlich für Balea/Balea med u. a.) und
`minimumTextHeightFraction`. Das klassische Vision-OCR
(`VNRecognizeTextRequest`) existiert bereits seit iOS 11 und
deckt damit ältere Geräte ab.

## 2. MLX Swift (mlx-swift-lm / MLXVLM)

### 2.1 Framework

`mlx-swift-lm` (MIT, Quelle:
<https://github.com/ml-explore/mlx-swift-lm>) ist aktiv: Release
3.31.4 (30.06.2026), 487 Commits, letzter Commit 03.09.2026. Die
`MLXVLM`-Library enthält "vision language model example
implementations". Im Beispiele-Repo
<https://github.com/ml-explore/mlx-swift-examples> läuft
MLXChatExample (iOS 17.0+/macOS 14.0+, Xcode 15+) mit LLMs **und**
VLMs, Bild-/Video-Input und Modell-Caching (Pfad:
`Applications/MLXChatExample/README.md`); VLM-Bild-Handling wird
aktiv gepflegt (Commit 15.06.2026: "fix VLM image handling on
iOS (PhotosPicker, EXIF…)").

Zusatz: `MLXFoundationModels` (im selben Repo) brückt MLX-Modelle
in Apples `FoundationModels.LanguageModel` — erfordert aber das
iOS/macOS 27.0 SDK, bringt also erst mit iOS 27 einen Mehrwert.

### 2.2 Welche VLMs laufen real auf iPhone

MLXVLM-Modell-Registry (Verzeichnis `Libraries/MLXVLM/Models`, per
GitHub-API am 2026-09-11 geprüft):

```text
FastVLM, Gemma3, Gemma4, Gemma4Assistant, GlmOcr, Idefics3,
LFM2VL, Mistral3, MuseGlimmer, Paligemma, Pixtral, Qwen25VL,
Qwen2VL, Qwen35, Qwen35MTP, Qwen35MoE, Qwen3VL, Qwen3VLMoE,
QwenVL, SmolVLM2
```

Bedeutung für unsere Kandidaten:

- **Gemma 3n E2B/E4B: multimodal NICHT in MLXVLM.** `Gemma3nText`
  existiert nur in `MLXLLM` (text-only; Registry-Presets
  `gemma3n_E2B_it_lm_4bit` / `gemma3n_E4B_it_lm_4bit`). Der
  multimodale Pfad für Gemma 3n ist LiteRT-LM (Abschnitt 3.2).
- **Qwen2.5-VL 3B:** läuft via `Qwen25VL.swift` — aber
  Research-Lizenz (Abschnitt 4.3).
- **SmolVLM2 2.2B:** läuft via `SmolVLM2.swift`, Apache-2.0, ok.
- **FastVLM 0.5B:** läuft via `FastVLM.swift` — aber
  Research-Lizenz (Abschnitt 4.3).
- **Gemma 4:** `Gemma4.swift`/`Gemma4Assistant.swift` vorhanden
  (Gemma 4: text+audio+image, Apache-2.0; Ankündigungs-Banner auf
  <https://ai.google.dev/gemma/docs/gemma-3n>).

### 2.3 Quantisierte Größen (HF-API, 2026-09-11 gemessen)

Gemessen via `https://huggingface.co/api/models/<id>?blobs=true`
(Summe aller Repo-Dateien), alle bei mlx-community:

| Modell | Repo-Größe | Quant. | Lizenz (HF) |
| --- | --- | --- | --- |
| gemma-3n-E2B-it-4bit | 4,50 GB | 4-bit | gemma (ToU) |
| gemma-3n-E4B-it-4bit | 5,86 GB | 4-bit | gemma (ToU) |
| Qwen2.5-VL-3B-Instruct-4bit | 3,09 GB | 4-bit | qwen-research |
| SmolVLM2-2.2B-Instruct-mlx | 4,50 GB | bf16 | apache-2.0 |
| SmolVLM-Instruct-4bit | 1,46 GB | 4-bit | — |
| FastVLM-0.5B-bf16 | 1,27 GB | bf16 | apple-amlr |

Auffällig: Gemma-3n-4bit ist wegen der PLE-Parameter (Per-Layer
Embedding, physisch im Repo, zur Laufzeit cachebar) deutlich
größer als die Parameterzahl vermuten lässt — E2B operiert mit
"nur" 1,91 B effektiven Parametern (Quelle:
<https://ai.google.dev/gemma/docs/gemma-3n>: MatFormer-Architektur,
PLE-Caching, MobileNet-V5-Vision-Encoder, 140+ Sprachen, 32K
Kontext). Ein 4-bit-Build von SmolVLM2-2.2B existiert bei
mlx-community nicht (nur bf16) — müsste selbst konvertiert werden.

### 2.4 Performance auf iPhone (Sekundärquellen)

Offizielle MLX-iOS-Benchmarks gibt es nicht; zwei
Community-Benchmarks, beide auf dem iPhone 17 Pro (A19 Pro,
iOS 26.4.2):

- MLX vs llama.cpp vs LiteRT-LM vs CoreML [3]: Decode
  Qwen3.5-2B **61,2 tok/s (MLX)** vs Gemma-4-E2B 47,5 tok/s (MLX)
  bzw. 55 tok/s (LiteRT-LM GPU). Peak-RAM: LiteRT-LM 641 MB vs
  MLX-Swift 2.900 MB (Gemma-4-E2B) bzw. 1.279 MB (Qwen3.5-2B).
  Fazit des Autors: "MLX / LiteRT-LM for speed, CoreML/ANE for
  memory".
- MLX-Blog (iPhone 17 Pro / iPad Pro) [4]: LFM2.5-1.2B 4-bit
  **59,7 tok/s** auf dem iPhone; Gemma-3-1B-QAT-4bit 37,1 tok/s.

Einschätzung (ohne Primärquelle): Ältere iPhones (A14/A15) sind
wegen geringerer Speicherbandbreite beim 4-bit-Decode deutlich
langsamer; die Flagship-Werte 25–60 tok/s skalieren dort grob in
die Hälfte oder darunter.

### 2.5 Eignung für Verpackungstext-OCR

- FastVLM-0.5B (Benchmark-Tabelle, Quelle:
  <https://huggingface.co/apple/FastVLM-0.5B>): TextVQA 64,5,
  DocVQA 82,5, OCRBench 63,9 (0,5B-Variante) — solide für große,
  klare Textflächen, aber 0,5 B ist für kleine
  Verpackungschriftarten (Zutatenlisten, Varianten-Bezeichnungen)
  zu schwach.
- Qwen2.5-VL-3B: laut Model-Card ("highly capable of analyzing
  texts, charts, icons, graphics, and layouts within images",
  <https://huggingface.co/Qwen/Qwen2.5-VL-3B-Instruct>) das
  stärkste OCR-Faible im Feld — aber Research-Lizenz (Abschnitt
  4.3), dafür für die App ungeeignet.
- SmolVLM2-2.2B: lizenzsauber, aber generisch schwächer bei
  Feintext.
- Fazit: Kein offenes 0,5–3-B-VLM schlägt Apples dedizierte
  OCR-Pipeline bei Drucktext; der Mehrwert eines VLMs liegt in der
  Interpretation (welcher String ist der Produktname, was ist
  Dekoration, welches der zwei Marken ist relevant), nicht in der
  Zeichenerkennung.

## 3. MediaPipe LLM Inference / LiteRT-LM

### 3.1 MediaPipe LLM Inference (iOS): Wartungsmodus, text-only

Die MediaPipe-LLM-Inference-API (Android/iOS/Web) ist offiziell in
den **maintenance-only-Modus** versetzt; Google empfiehlt die
Migration zu LiteRT-LM (Banner, Quelle:
<https://developers.google.com/edge/mediapipe/solutions/genai/llm_inference>,
Seite zuletzt aktualisiert 12.06.2026). Unterstützte Modelle:
Gemma-3n E2B/E4B (`.litertlm`), Gemma-3-1B, Gemma-2-2B.

Für iOS ist die Task text-only: Die Task-Definition listet unter
"Task inputs" nur "Text prompt", der iOS-Guide
(<https://developers.google.com/edge/mediapipe/solutions/genai/llm_inference/ios>,
CocoaPods `MediaPipeTasksGenAI`) zeigt `generateResponse
(inputText:)`. Die Gemma-3n-Multimodalität (Bild/Audio) wird von
MediaPipe primär für Android/Web beworben; für iOS bleibt damit
praktisch nur der LiteRT-LM-Weg (3.2).

### 3.2 LiteRT-LM: production-ready, Swift Early Preview

LiteRT-LM (Quelle:
<https://developers.google.com/edge/litert-lm/overview>) ist der
"production-ready orchestration layer": Cross-Platform (Android,
iOS, Web, Desktop, IoT), CPU/GPU-Beschleunigung, Multi-Modality
(Vision + Audio), Tool-Use/Function-Calling, Modell-Support u. a.
Gemma, Llama, Phi-4, Qwen. Status der Swift-API: **Early Preview**
("Native iOS and macOS integration with specialized Metal
support").

Swift-API-Details (Quelle:
<https://developers.google.com/edge/litert-lm/swift>, SPM-Paket
`google-ai-edge/LiteRT-LM` ab 0.12.0):

- **Bild-Input auf iOS: unterstützt** — `Content.imageFile(path)`
  plus `visionBackend: .cpu()` in der Engine-Konfiguration.
- Audio-Input, Tool-Calling (`@ToolParam`), MTP-Spekulatives
  Decoding, Reasoning/Thinking-Kanäle.
- Referenz-App: Google AI Edge Gallery, im App Store
  (id6749645337), läuft vollständig offline über LiteRT-LM.

Modelle: Gemma-3n-E2B (2.965 MB) / E4B (4.235 MB) als
`.litertlm`; aktuelles Featured-Modell **Gemma-4-E2B (2,58 GB)**,
Apache-2.0 (Gemma-4-Lizenz,
<https://ai.google.dev/gemma/apache_2>).

### 3.3 Benchmark (Gemma-4-E2B, iPhone 17 Pro, Primärquelle)

Tabelle von der LiteRT-LM-Overview-Seite (3.2):

| Backend | Prefill (tk/s) | Decode (tk/s) | TTFT (s) | Peak CPU-Mem (MB) |
| --- | --- | --- | --- | --- |
| CPU | 532 | 25 | 1,9 | 607 |
| GPU (Metal) | 2.878 | 56 | 0,3 | 1.450 |

→ ~56 tok/s Decode auf dem Flagship; 607 MB Peak-RAM (CPU-Backend)
machen das Modell auch für RAM-armere Szenarien tragbar.

## 4. Praktische Constraints

### 4.1 App-Store-Größenlimits & ODR

On-demand-resources-Limits (Quelle [5]):

- Thinned App Bundle: **4 GB** (iOS 18+; davor 2 GB); zusätzlich
  gilt für Uploads "total uncompressed size < 4 GB" (Quelle [6]).
- ODR-Limits iOS 18+: Asset-Pack bis 8 GB, initial installierte
  Tags ohne Limit, gehostete ODR bis 70 GB, in use ohne Limit.
- **Wichtig: ODR ist seit iOS 27 deprecated** (Hinweis auf der
  selben Seite); Apple empfiehlt die Migration zu **Background
  Assets**
  (<https://developer.apple.com/documentation/backgroundassets>).

Konsequenz: Ein 4,5-GB-Modell (Gemma-3n-E2B-4bit, SmolVLM2-bf16)
passt nicht ins Bundle; selbst 3,09 GB (Qwen2.5-VL-3B-4bit) sind
am 4-GB-Limit nur noch knapp.

### 4.2 Download am ersten Start statt Bundling

Beide Referenz-Apps laden das Modell zur Laufzeit: MLXChatExample
zieht Modelle von HuggingFace und cacht sie lokal (README,
Abschnitt 2.1); die FastVLM-Demo-App (iOS 18.2+/macOS 15.2+)
liefert `get_pretrained_mlx_model.sh` für 0,5B/1,5B/7B und betont
"All predictions are processed privately and securely using
on-device models" (Quelle:
<https://github.com/apple/ml-fastvlm/blob/main/app/README.md>).
Für unsere App: Modell als First-Launch-Download (Fortschritt +
Speicher-Check) oder via Background Assets; kein Bundling.

### 4.3 Modell-Lizenzen: Auslieferung in der App erlaubt?

| Modell | Lizenz | In App auslieferbar? |
| --- | --- | --- |
| Gemma 3n E2B/E4B | Gemma Terms of Use | Ja (kommerziell erlaubt, mit Notice) |
| Gemma 4 E2B/E4B | Apache-2.0 | Ja |
| SmolVLM2 2.2B | Apache-2.0 | Ja |
| Qwen2.5-VL 3B | Qwen Research License | **Nein** (nur Nicht-Kommerziell) |
| FastVLM 0,5–7B | Apple ML Research License | **Nein** (nur Research) |

- **Gemma 3n** ist im Appendix der Gemma Terms of Use gelistet
  (Stand 01.04.2026, Quelle: <https://ai.google.dev/gemma/terms>):
  kommerzielle Nutzung erlaubt ("licensed for responsible
  commercial use, allowing you to tune and deploy it in your own
  projects and applications", Quelle:
  <https://ai.google.dev/gemma/docs/gemma-3n>); Distribution
  verlangt eine Notice-Datei und die Weitergabe der
  Use-Restrictions. Gemma 4 hat eine eigene Apache-2.0-Lizenz
  (<https://ai.google.dev/gemma/apache_2>).
- **SmolVLM2 2.2B:** Apache-2.0, verifiziert an upstream
  (HuggingFaceTB) und am mlx-community-Repo (HF-API, 2026-09-11).
- **Qwen2.5-VL 3B:** Model-Card ohne Lizenz-Tag, README verweist
  mit `license_name: qwen-research` auf die LICENSE-Datei
  (Quelle: <https://huggingface.co/Qwen/Qwen2.5-VL-3B-Instruct>):
  "Qwen RESEARCH LICENSE AGREEMENT" (19.09.2024), Lizenzgrant
  "FOR NON-COMMERCIAL PURPOSES ONLY", kommerzielle Nutzung nur
  nach Lizenzanfrage an Alibaba Cloud. Der 4-bit-Quant von
  mlx-community erbt dieselbe Lizenz (README verweist auf die
  originale LICENSE). Für eine rein private, nicht verteilte
  Nutzung auf dem eigenen Gerät vertretbar; für jede
  Auslieferung (App Store, TestFlight) unbrauchbar.
- **FastVLM:** HF-Lizenztag `apple-amlr`; `LICENSE_MODEL` im
  Repo (Quelle:
  <https://github.com/apple/ml-fastvlm/blob/main/LICENSE_MODEL>):
  "Research Purposes … does not include any commercial
  exploitation, product development or use in any commercial
  product or service". Die Code-Lizenz (LICENSE) des Repos regelt
  nur den Code, nicht die Gewichte.

### 4.4 Thermik & Batterie auf älteren iPhones

Keine Primärdaten (Apple/Google) für ältere iPhones gefunden —
honeste Lücke dieser Recherche. Indizien:

- Der Apple-Intelligence-Pfad (Foundation Models) scheidet ab
  iPhone 15 Pro (A17 Pro) aus — ältere Geräte kommen dort gar
  nicht in Frage (Abschnitt 1.5).
- MLX-Pfad: formal ab iOS 17 (MLXChatExample-Requirement, also
  auch iPhone 12/A14); Decode-Benchmarks existieren nur für das
  iPhone 17 Pro (Abschnitt 2.4). 4-bit-Decode ist
  speicherbandbreiten-limitiert, ältere SoCs sind erfahrungsgemäß
  deutlich langsamer (Einschätzung, keine Quelle).
- RAM: Peak 0,6 GB (LiteRT-LM CPU) bis 2,9 GB (MLX, Gemma-4-E2B)
  auf dem Flagship; auf 4-GB-Geräten (iPhone 12/13) ist ein
  4,5-GB-Download plus ~2-GB-RAM-Fußabdruck grenzwertig.
- Praktisch: Zielgerät auf A17 Pro+ setzen; ältere Geräte
  bekommen den OCR-Pfad (Vision-OCR läuft ohne LLM und ohne
  Modell-Download, Abschnitt 1.6).

## 5. Vergleich & Empfehlung

### 5.1 Vergleichstabelle

| Ansatz | Modell | Download | Bild-Input | Lizenz | Min. iOS |
| --- | --- | --- | --- | --- | --- |
| Foundation Models | SystemLanguageModel | 0 | Ja (27+) | Apple | 27 (AI) |
| Foundation Models + PCC | PCC (32K) | 0 | Ja (27+) | Apple | 27 (AI) |
| MLXVLM + SmolVLM2-2.2B | bf16 | 4,5 GB | Ja | Apache-2.0 | 17 |
| MLXVLM + Qwen2.5-VL-3B | 4-bit | 3,1 GB | Ja | Research ✗ | 17 |
| MLXVLM + FastVLM-0.5B | bf16 | 1,3 GB | Ja | Research ✗ | 17 |
| LiteRT-LM Swift (Preview) | Gemma-4-E2B | 2,6 GB | Ja | Apache-2.0 | n. a. |
| Vision-OCR + Katalog | RecognizeTextRequest | 0 | OCR | Apple | 18 (neu) |

("n. a." = von Google nicht angegeben; "AI" = nur
Apple-Intelligence-Geräte.)

### 5.2 Empfehlung

(a) **Bester on-device Kandidat "Produktfoto → Produktname":**

1. **Primär: Vision-OCR + Katalog-Matching (kein LLM).**
   `RecognizeTextRequest` (accurate, `customWords` = Vokabular aus
   Marken-/Produktnamen) → Normalisierung → Match gegen den
   lokalen dm-Katalog. Deterministisch, schnell, kein
   Modell-Download, keine Lizenzfragen, ab iOS 18 (alt: iOS 11).
   Ergänzend `DetectBarcodesRequest` → GTIN direkt auflösen
   (siehe barcode-product-data-sources.md).
2. **Zweitpfad (Fuzzy): Foundation Models, iOS 27.**
   `SystemLanguageModel` + `Attachment` (Produktfoto) +
   `@Generable`-Struct (name, brand, confidence) +
   `OCRTool`/`BarcodeReaderTool` + eigener Tool
   `matchCatalog(text) → Kandidaten`. Kein Download, privates
   on-device Modell; 4096–8192 Tokens reichen für ein Foto mit
   kompaktem Prompt. Auf AI-Geräten der Pfad mit dem geringsten
   Entwicklungsaufwand.
3. **Eigene-VLM-Pfad (nur wenn iOS 17–26 ohne AI oder
   Plattform-Unabhängigkeit nötig):** SmolVLM2-2.2B via MLXVLM
   (einziger lizenzsauberer VLM-Kandidat; 4,5 GB bf16, 4-bit
   selbst konvertieren) oder Gemma-4-E2B via LiteRT-LM (Swift
   Early Preview, 2,6 GB, Apache-2.0). Qwen2.5-VL-3B und FastVLM
   aussortieren (Research-Lizenzen, Abschnitt 4.3).

(b) **Ist Apple-Vision-OCR + Katalog-Matching die robustere
Alternative?** Ja, als Primärpfad klar: deterministische
Zeichenerkennung schlägt kleine VLMs bei Drucktext, und das
Matching gegen den eigenen Katalog eliminiert Halluzinationen
(VLMs erfinden Produktnamen). Der VLM-Zweitpfad ist nur für den
Fuzzy-Rest da: verformte/abgenutzte Etiketten, fremde Marken,
mehrere Produkte im Bild, fehlende Katalogtreffer.

(c) **Wann serverseitiger Fallback nötig ist:**

- On-device-OCR liefert zu wenig Text oder das Matching schlägt
  fehl (neues Produkt, Nicht-dm-Marke, stark verformtes Etikett).
- **Erster Fallback: PCC** (Apple, iOS 27, kostenlos bis 2 Mio.
  Downloads): keine eigene Infrastruktur, Apple-Privacy-Garantien,
  32K Kontext + Reasoning — und es nimmt das Foto direkt als
  Attachment.
- **Eigener Server (VLM-API) nur**, wenn PCC nicht verfügbar ist
  (iOS < 27, PCC-Limit erreicht) oder Apple-Privacy-Garantien
  nicht ausreichen; dann Foto + OCR-Text + Katalog-Kandidaten
  mitgeben, damit der Server nur disambiguieren muss.

## Quellen (lange URLs)

<!-- markdownlint-disable MD013 -->

- [1] "Analyzing images with multimodal prompting" (Apple
  Developer Doku):
  <https://developer.apple.com/documentation/foundationmodels/analyzing-images-with-multimodal-prompting>
- [2] "Managing the context window" (Apple Developer Doku):
  <https://developer.apple.com/documentation/foundationmodels/managing-the-context-window>
- [3] "Which runtime is fastest? MLX vs llama.cpp vs LiteRT-LM vs
  CoreML" (dev.to, john-rocky, Sekundärquelle):
  <https://dev.to/john-rocky/on-device-llm-on-iphone-which-runtime-is-fastest-mlx-vs-llamacpp-vs-litert-lm-vs-coreml-1b42>
- [4] "How Fast Are On-Device LLMs on iPhone 17 Pro and iPad Pro?"
  (rickytakkar.com, Sekundärquelle):
  <https://rickytakkar.com/blog_russet_mlx_benchmark.html>
- [5] "On-demand resources size limits" (App Store Connect Help):
  <https://developer.apple.com/help/app-store-connect/reference/app-uploads/on-demand-resources-size-limits/>
- [6] "Maximum build file sizes" (App Store Connect Help):
  <https://developer.apple.com/help/app-store-connect/reference/app-uploads/maximum-build-file-sizes/>

<!-- markdownlint-enable MD013 -->

**Antwort auf die Kernfrage:** Ja — on-device "Foto →
Produktname" ist auf aktuellen iPhones (A17 Pro/A18/A19-Generation)
realistisch, mit Einschränkungen: Der robusteste Pfad ist
Vision-OCR + Katalog-Matching (iOS 18+, auch auf älteren
Geräten); ein echtes Vision-LLM on device gibt es erst mit iOS 27
(Foundation Models, nur Apple-Intelligence-Geräte). Auf älteren
iPhones (A14/A15) bleibt faktisch nur der OCR-Pfad; offene VLMs
sind dort langsam und bei 4,5-GB-Modellen speicher-kritisch.
Konkrete Empfehlung: OCR + Katalog als Kern, Foundation-Models-VLM
(iOS 27, Bild-`Attachment` + `OCRTool`) als Fuzzy-Zweitpfad, PCC
als Server-Fallback; eigene VLMs (SmolVLM2 oder Gemma-4-E2B) nur
als Backup, wenn iOS < 27 oder ein Betrieb ohne
Apple-Intelligence-Gerät nötig ist.
