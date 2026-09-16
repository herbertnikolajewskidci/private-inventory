# Recherche-Stand: 2026-09-16

## Kernfrage

Welches Apple-API ist der aktuelle Standard
(iOS 26 / Xcode 26.6) für die On-Device
Texterkennung (OCR) von Produktetiketten
(Deutsch + Englisch) in einer Swift 6 /
SwiftUI App, um die Ergebnisse zur
Bearbeitung und Suche bereitzustellen?

## Findings

### 1. Vision Framework: Swift-native API

Seit iOS 18 wurde das Vision Framework
durch eine moderne, Swift-native API
ergänzt. Anstelle der klassenbasierten
`VNRecognizeTextRequest` wird nun die
`RecognizeTextRequest` (Struct)
empfohlen, die vollständig auf
**Swift Concurrency** (async/await)
basiert.

- **Signatur & Typen**:
  - **Request**: `RecognizeTextRequest`
    (Struct).
  - **Ausführung**: `try await
    request.perform(on: cgImage)`
    oder `try await
    request.perform(on: url)`.
  - **Konfiguration**:
    - `recognitionLevel`: `.accurate`
      (empfohlen für Produktetiketten)
      oder `.fast`.
    - `recognitionLanguages`: Ein
      Array von Sprach-Identifikatoren
      (z. B. `Locale.Language(identifier:
      "de-DE")`).
    - `usesLanguageCorrection`: Bool.
    - `minimumTextHeightFraction`:
      Request-level Schwellenwert für die
      Mindesttexthöhe (eine Konfidenz-Schwelle
      gibt es NICHT am Request — die
      Konfidenz wird pro Kandidat geliefert
      und in der App nachgefiltert, siehe
      `TextRecognizer.minimumConfidence`).
  - **Orientierung**: `perform(on:
    orientation:)` nimmt
    `CGImagePropertyOrientation` — der
    Aufrufer muss die `UIImage.orientation`
    mappen (Porträt-/gespiegelte Fotos
    sonst in Roh-Orientierung).
  - **Ergebnisse**: `Self.Result`
    (`[TextObservation]`), je Observation
    `topCandidates(1)` mit `.string` und
    `.confidence`.
- **Swift 6 & Concurrency**: Die neue
  API ist für Actors optimiert. Die
  Ausführung erfolgt asynchron und
  entlastet den Main Thread automatisch.

### 2. API-Status (iOS 26)

`VNRecognizeTextRequest` ist weiterhin
vorhanden (für Legacy-Support), wird
aber für neue Projekte nicht mehr
empfohlen. `RecognizeTextRequest` ist
der primäre Weg. Die Sprachqualität
wurde durch verbesserte Modelle für die
Texterkennung in komplexen Umgebungen
(wie Produktverpackungen) signifikant
erhöht.

### 3. Extraktion von Textzeilen und Konfidenz

Um alle erkannten Textzeilen sowie deren
Konfidenzwerte zu erhalten, iteriert man
über die `VNRecognizedTextObservation`-
Objekte.

- **Typen**:
  - `VNRecognizedTextObservation`:
    Repräsentiert eine erkannten
    Textblock/Zeile.
  - `topCandidates(_:)`: Liefert die
    wahrscheinlichsten Kandidaten für
    diese Zeile.
  - `VNRecognizedTextCandidate`:
    Enthält das Property `.string`
    (der Text) und `.confidence` (Float-
    Wert für die Sicherheit).

### 4. Zugriff auf die Mediathek (PhotosPicker)

Die Nutzung von `PhotosPicker` (aus
`PhotosUI`) ist der moderne Standard.

- **Workflow**: `PhotosPickerItem` $\rightarrow$
  `loadTransferable(type: Data.self)`
  $\rightarrow$ `UIImage(data: data)`.
- **Berechtigungen**:
  - `PhotosPicker`: Benötigt **keinen**
    Eintrag in der `Info.plist` (kein
    `NSPhotoLibraryUsageDescription`),
    da der Prozess außerhalb der App
    läuft (Out-of-process).
  - **Kamera**: Erfordert weiterhin
    zwingend `NSCameraUsageDescription`
    für die Live-Aufnahme.

### 5. On-Device & Offline-Fähigkeit

Die gesamte Verarbeitung findet lokal
auf dem Gerät statt. Es erfolgt kein
Netzwerkaufruf. Die Unterstützung für
Deutsch (`de-DE`) und Englisch
(`en-US`) ist nativ und offline
verfügbar.

### 6. Verfügbarkeit

Die neuen APIs sind ab iOS 18.0
verfügbar. Für das Zielsystem iOS
26.0 ist die Nutzung von
`RecognizeTextRequest` ohne
`@available` Checks möglich.

## Empfehlung für die App

Für die Implementierung der Produkt-
Suche wird die asynchrone
`RecognizeTextRequest` API verwendet.

### Code-Entwurf (Swift 6)

```swift
import SwiftUI
import Vision

@MainActor
struct OCRService {
    enum OCRError: Error {
        case invalidImage
    }

    /// Erkennt Text aus einem UIImage asynchron
    func recognizeProductText(from image: UIImage) async throws -> [TextLine] {
        guard let cgImage = image.cgImage else {
            throw OCRError.invalidImage
        }

        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US", "de-DE"]

        // Ausführung auf dem Hintergrund-Thread durch async/await
        let observations = try await request.perform(on: cgImage)

        return observations.compactMap { observation in
            // Wir nehmen den besten Kandidaten pro Zeile
            guard let topCandidate = observation.topCandidates(1).first else {
                return nil
            }
            return TextLine(
                text: topCandidate.string,
                confidence: topCandidate.confidence
            )
        }
    }
}

struct TextLine: Identifiable, Sendable {
    let id = UUID()
    let text: String
    let confidence: Float
}
```
