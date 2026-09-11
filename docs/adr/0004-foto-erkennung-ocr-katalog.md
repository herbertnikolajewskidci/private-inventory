# Foto-Erkennung: OCR + Katalog-Match statt On-device-VLM

Unbekanntes Produkt (GTIN nirgends auflösbar): Foto aufnehmen →
On-device-OCR (Vision `RecognizeTextRequest`) → Matching gegen den
dm-Katalog → Nutzer bestätigt den Treffer → Produkt wird mit der
GTIN verknüpft. Manuelle Eingabe bleibt als dauerhafter Fallback.
Ein On-device-VLM ist out of scope: Das Primärgerät (iPhone 13 Pro
Max, A15) ist nicht Apple-Intelligence-fähig; offene VLMs sind
1,3–4,5 GB schwer, bei Verpackungs-Feintext schwächer als Apples
OCR und teils research-lizenziert (Qwen2.5-VL, FastVLM). Beleg:
`docs/research/on-device-vision-llm-ios.md` (2026-09-11).

## Considered Options

- On-device-VLM (Foundation Models, iOS 27): verworfen — läuft
  nicht auf dem Primärgerät (A15), nur auf Apple-Intelligence-
  Geräten.
- Eigene VLMs (SmolVLM2, Gemma-4-E2B via MLX Swift / LiteRT-LM):
  verworfen — Download-/RAM-Last, Lizenzfallen bei den OCR-starken
  Kandidaten, schwächer bei Feintext als dedizierte OCR.
- Apple Private Cloud Compute: nicht nötig, solange der
  On-prem-Weg (unten) existiert.

## Consequences

- OCR läuft offline; das Katalog-Matching braucht Netz. Ohne
  Empfang landet der OCR-Text in der Queue der Ungelösten Scans
  (ADR-0003) und wird später aufgelöst — der Scan-Flow im Keller
  bricht nie.
- Festgehaltener späterer Ausbau (nicht v1): selbst gehostetes VLM
  auf dem heimischen Unraid-Server (2× RTX 4070, Ollama) als
  Foto-Erkennungs-Backend für Fuzzy-Fälle (verformte Etiketten,
  fremde Marken, keine Katalogtreffer). Ersetzt das verworfene
  On-device-VLM und macht auch Apples PCC überflüssig.
  Voraussetzung: Der Server muss aus dem Keller erreichbar sein
  (WiFi/VPN); sonst greift weiterhin die Queue.
