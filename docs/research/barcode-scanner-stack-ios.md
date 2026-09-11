# Barcode-Scanner-Stack für iOS: VisionKit vs. AVFoundation

Recherche-Stand: 2026-09-11. Alle API-Fakten wurden direkt aus den
offiziellen Apple-Developer-Dokumentationen und WWDC-Vorträgen verifiziert.
Kernfrage: Welcher Barcode-Scanning-Stack eignet sich für eine native
SwiftUI-App unter iOS 18 mit Einzelscan-Charakteristik?

## TL;DR

- **Empfehlung:** VisionKit `DataScannerViewController` ist die empfohlene
  Wahl für private-inventory.
- VisionKit bietet eine vollständige High-Level-Lösung (fertiges Kamera-Pass-
  Through-UI, hardwarebeschleunigte Erkennung, Tap-to-Focus, Zoom-Gesten,
  Region-of-Interest in View-Koordinaten) und benötigt nur einen Bruchteil
  des Codes im Vergleich zu AVFoundation.
- Alle fachlichen Anforderungen werden vollständig erfüllt:
  - **Einzelscan / Schutz vor Doppelscans:** `recognizesMultipleItems: false`
    beim Initialisieren verhindert Mehrfacherkennung im Frame. Nach dem ersten
    Ergebnis (`dataScanner(_:didTapOn:)` oder Auslesen via
    `dataScanner(_:didAdd:allItems:)`) stoppt ein direkter Aufruf von
    `stopScanning()` die Pipeline sofort.
  - **Symbologien (EAN-8, EAN-13, UPC-A):** Unterstützt via
    `VNBarcodeSymbology.ean8` und `.ean13`. UPC-A ist standardkonform eine
    Teilmenge von EAN-13 (mit führender Null) und wird von Apple Vision
    als 13-stellige `.ean13` erkannt.
  - **Zielgerät & Deployment:** iPhone 13 Pro Max (A15 Bionic) übertrifft
    die Systemanforderung (A12 Bionic) bei weitem; Deployment-Target iOS 18
    liegt komfortabel über der Mindestversion iOS 16.0.
  - **Haptik & Re-Arm:** Haptik wird im Scan-Callback über SwiftUIs
    `.sensoryFeedback(.success, trigger: ...)` oder `UIImpactFeedbackGenerator`
    ausgelöst; Re-Arm erfolgt durch einfaches erneutes `try? startScanning()`.
  - **Torch:** Kann parallel über `AVCaptureDevice` gesteuert werden,
    sofern die Kamera-Session läuft.
- **Größter Fallstrick:** `DataScannerViewController.isSupported` ist im
  iOS-Simulator immer `false` (Kamera-Hardware und Neural Engine fehlen). Für
  Simulator-Entwicklung und Previews ist ein Abstraktions-Layer bzw.
  Mock-Scanner zwingend erforderlich.

---

## 1. Stack-Vergleich: VisionKit vs. AVFoundation (+ Vision)

Apple bietet zwei primäre Wege, um Barcodes in einer iOS-App live zu
scannen:

| Merkmal | VisionKit | AVFoundation |
| --- | --- | --- |
| Basis | iOS 16.0+ | iOS 6.0+ |
| Ebene | UIViewController | Capture-Pipeline |
| SwiftUI | Representable | PreviewLayer-Host |
| Code | ~60 Zeilen | ~300 Zeilen |
| Chip | A12 Bionic+ | beliebig |
| Sim | Nein | Nein |
| Symbole | VNBarcodeSymbology | AVMetadataObject |
| Punkte | View-Punkte | Normalisiert [0,1] |
| Reticle | Integriert | Custom Code |
| Fokus | Integriert | Manuell |

Quelle VisionKit:
<https://developer.apple.com/documentation/visionkit/datascannerviewcontroller>

Quelle AVFoundation:
<https://developer.apple.com/documentation/avfoundation/avcapturemetadataoutput>

---

## 2. Detaillierte Analyse für private-inventory

### 2.1 Eignung für Einzelscan und Schutz vor versehentlichen Doppelscans

Das Zielsystem verlangt einen Button-getriggerten Einzelscan: Der Nutzer
tippt auf "Scannen", richtet die Kamera aus, genau ein Barcode wird erfasst,
und der Scanner beendet die Erfassung (kein Dauer-Scan).

In `DataScannerViewController` lässt sich dies deklarativ und im Lifecycle
exakt abbilden:

- Beim Initialisieren wird `recognizesMultipleItems: false` gesetzt:

  ```swift
  DataScannerViewController(
      recognizedDataTypes: [.barcode(symbologies: [.ean8, .ean13])],
      qualityLevel: .balanced,
      recognizesMultipleItems: false,
      isHighFrameRateTrackingEnabled: false,
      isHighlightingEnabled: true
  )
  ```

- **Erfassungs-Modi:**
  1. *Automatisch beim ersten Erscheinen:* Der Delegate implementiert
     `dataScanner(_:didAdd:allItems:)`. Sobald das erste Item erkannt wird,
     wird die GTIN extrahiert und sofort `scanner.stopScanning()` aufgerufen.
  2. *Durch Antippen des hervorgehobenen Barcodes:* Der Delegate implementiert
     `dataScanner(_:didTapOn: item)` und ruft darin `scanner.stopScanning()` auf.
- **Re-Arm:** Für den nächsten Scan genügt ein erneuter Aufruf von
  `try? scanner.startScanning()`. Es muss keine Session neu aufgebaut werden.

Quellen:

- <https://developer.apple.com/documentation/visionkit/datascannerviewcontroller/init(recognizeddatatypes:qualitylevel:recognizesmultipleitems:ishighframeratetrackingenabled:ispinchtozoomenabled:isguidanceenabled:ishighlightingenabled:)>
- <https://developer.apple.com/documentation/visionkit/datascannerviewcontroller/startscanning()>
- <https://developer.apple.com/documentation/visionkit/datascannerviewcontroller/stopscanning()>
- <https://developer.apple.com/documentation/visionkit/datascannerviewcontrollerdelegate>

### 2.2 Barcode-Symbologien: EAN-8, EAN-13, UPC-A

`DataScannerViewController` konfiguriert Barcodes über
`DataScannerViewController.RecognizedDataType.barcode(symbologies:)`,
wobei das Array aus `VNBarcodeSymbology`-Werten des Vision-Frameworks
besteht:

- **EAN-8:** `VNBarcodeSymbology.ean8`
- **EAN-13:** `VNBarcodeSymbology.ean13`
- **UPC-A:** Im GS1- und Barcode-Standard ist UPC-A ein 12-stelliger Code,
  der mathematisch und optisch identisch mit einem EAN-13-Code ist, dessen
  erste Ziffer eine führende Null (`0`) ist. Apple Vision und VisionKit
  bieten keinen separaten Identifikator `.upca`, sondern erkennen UPC-A
  automatisch als 13-stellige Zeichenkette unter `VNBarcodeSymbology.ean13`
  (mit führender Null). Für reine UPC-E-Codes existiert separat
  `VNBarcodeSymbology.upce`.

Der erkannte String-Payload wird über die Eigenschaft
`payloadStringValue` der Struktur `RecognizedItem.Barcode` ausgelesen:

```swift
if case .barcode(let barcode) = item {
    let gtin = barcode.payloadStringValue // z. B. "4066447966008"
}
```

Quellen:

- <https://developer.apple.com/documentation/visionkit/datascannerviewcontroller/recognizeddatatype/barcode(symbologies:)>
- <https://developer.apple.com/documentation/vision/vnbarcodesymbology>
- <https://developer.apple.com/documentation/visionkit/recognizeditem/barcode/payloadstringvalue>

### 2.3 Torch (Taschenlampe)

`DataScannerViewController` kapselt die `AVCaptureSession` intern und bietet
kein eigenes UI-Element oder eine eigene Property für die Taschenlampe.
Allerdings kann die Taschenlampe der Standard-Rückkamera parallel über
AVFoundation gesteuert werden, während `DataScannerViewController` aktiv ist:

```swift
import AVFoundation

func setTorch(enabled: Bool) {
    guard let device = AVCaptureDevice.default(for: .video),
          device.hasTorch else { return }
    do {
        try device.lockForConfiguration()
        device.torchMode = enabled ? .on : .off
        device.unlockForConfiguration()
    } catch {
        // Torch-Konfiguration fehlgeschlagen
    }
}
```

Die Steuerung kann über einen SwiftUI-Button im Overlay (oder über
`overlayContainerView` von VisionKit) platziert werden.

Quellen:

- <https://developer.apple.com/documentation/avfoundation/avcapturedevice/torchmode-swift.property>
- <https://developer.apple.com/documentation/avfoundation/avcapturedevice/lockforconfiguration()>

### 2.4 Haptisches Feedback bei Treffer

VisionKit spielt beim reinen Erkennen keine automatische Haptik ab. Dies ist
für den Workflow optimal, da die App selbst bestimmen kann, wann Feedback
erfolgt (z. B. nur bei gültiger GTIN-Länge oder erfolgreichem Scan):

In SwiftUI (Deployment-Target iOS 18) kann modernes Feedback deklarativ
per View-Modifier ausgelöst werden:

```swift
.sensoryFeedback(.success, trigger: scannedGtin)
```

Alternativ imperativ im Delegate-Handler oder ViewModel:

```swift
let generator = UIImpactFeedbackGenerator(style: .medium)
generator.prepare()
generator.impactOccurred()
```

Quellen:

- <https://developer.apple.com/documentation/swiftui/view/sensoryfeedback(_:trigger:)>
- <https://developer.apple.com/documentation/uikit/uiimpactfeedbackgenerator>

---

## 3. Fallstricke & Plattform-Besonderheiten

### 3.1 Hardware-Anforderungen und Simulator-Support

- **A12 Bionic Mindestanforderung:** `DataScannerViewController.isSupported`
  prüft zur Laufzeit, ob das Gerät mindestens einen Apple A12 Bionic Chip
  (eingeführt 2018 mit iPhone XS / XR) besitzt.
  - *Projekt-Kontext:* Das Zielgerät ist ein **iPhone 13 Pro Max (A15 Bionic)**.
    Damit ist die Hardware-Unterstützung uneingeschränkt gegeben.
- **Simulator-Restriktion:** Im Xcode-Simulator liefert
  `DataScannerViewController.isSupported` immer `false`, da im Simulator weder
  die Kamera noch die erforderliche Neural-Engine-Pipeline zur Verfügung stehen.
- **Konsequenz für die Entwicklung:**
  Der Scanner-Aufruf muss abgesichert werden:

  ```swift
  guard DataScannerViewController.isSupported else {
      // Fallback für Simulator: Manuelle Eingabe oder Mock-Scan
      return
  }
  ```

  Für SwiftUI Previews und Tests im Simulator sollte das Barcode-Scanning
  hinter einem Protokoll (z. B. `BarcodeScannerServiceProtocol`) abstrahiert
  werden, damit im Simulator ein Mock (z. B. Test-Barcode per Knopfdruck)
  eingespielt werden kann.

Quellen:

- <https://developer.apple.com/documentation/visionkit/datascannerviewcontroller/issupported>
- <https://developer.apple.com/documentation/visionkit/scanning-data-with-the-camera#Handle-when-the-scanner-becomes-unavailable>

### 3.2 Kamera-Permission und Fehlerbehandlung

- **Info.plist:** Der Schlüssel `NSCameraUsageDescription`
  (`Privacy - Camera Usage Description`) ist zwingend erforderlich. Fehlt
  dieser Schlüssel, stürzt die App beim Versuch, auf die Kamera zuzugreifen,
  mit einem SIGABRT ab.
- **Zustandsprüfung vor Anzeige:**
  `DataScannerViewController.isAvailable` gibt an, ob die Kamera derzeit
  verfügbar ist (prüft u. a. Kamera-Berechtigung und Einschränkungen wie
  Bildschirmzeit/MDM).
- **Fehler-Callback:** Falls während des Betriebs der Zugriff entzogen wird
  oder die Kamera blockiert ist, ruft VisionKit den Delegate-Callback
  `dataScanner(_:becameUnavailableWithError:)` auf
  (mögliche Fehler: `ScanningUnavailable.unsupported` oder
  `ScanningUnavailable.cameraRestricted`).

Quellen:

- <https://developer.apple.com/documentation/bundleresources/information-property-list/nscamerausagedescription>
- <https://developer.apple.com/documentation/visionkit/datascannerviewcontroller/isavailable>
- <https://developer.apple.com/documentation/visionkit/datascannerviewcontroller/scanningunavailable>

### 3.3 Minimale iOS-Versionen

- `DataScannerViewController`: **iOS 16.0+**
- `SensoryFeedback` (SwiftUI): **iOS 17.0+**
- Projekt-Deployment-Target laut ADR-0001: **iOS 18.0+**
- Alle eingesetzten APIs sind unter iOS 18 vollständig etabliert und stabil;
  es sind keine `@available`-Weichen erforderlich.

---

## 4. SwiftUI-Architekturmuster

Da `DataScannerViewController` ein UIKit `UIViewController` ist, wird er in
SwiftUI über `UIViewControllerRepresentable` eingebunden:

```swift
import SwiftUI
import VisionKit

struct DataScannerView: UIViewControllerRepresentable {
    @Binding var isScanning: Bool
    let onScanned: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.ean8, .ean13])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(
        _ uiViewController: DataScannerViewController,
        context: Context
    ) {
        if isScanning && !uiViewController.isScanning {
            try? uiViewController.startScanning()
        } else if !isScanning && uiViewController.isScanning {
            uiViewController.stopScanning()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let parent: DataScannerView

        init(_ parent: DataScannerView) {
            self.parent = parent
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard parent.isScanning,
                  let first = addedItems.first,
                  case .barcode(let barcode) = first,
                  let payload = barcode.payloadStringValue else { return }

            // Sofort stoppen zur Vermeidung von Mehrfachscans
            dataScanner.stopScanning()
            parent.isScanning = false
            parent.onScanned(payload)
        }
    }
}
```

Quelle UIViewControllerRepresentable:
<https://developer.apple.com/documentation/swiftui/uiviewcontrollerrepresentable>

---

## 5. Fazit & Empfehlung

Für das Projekt **private-inventory** ist **VisionKit `DataScannerViewController`**
eindeutig der geeignetere Stack:

1. **Geringe Komplexität:** Das Projekt wird von KI-Agenten gepflegt; der
   Nutzer ist DevOps-Engineer ohne iOS-Hintergrund (siehe ADR-0001).
   Ein 60-Zeilen `UIViewControllerRepresentable`-Wrapper ist wartungsarm,
   robuster und weitaus weniger anfällig für Threading- oder Lifecycle-Bugs
   als eine manuelle AVFoundation-Capture-Pipeline mit 300+ Zeilen Code.
2. **Native iOS-Erfahrung:** VisionKit bringt automatische Barcode-Hervorhebung,
   Pinch-to-Zoom und Tap-to-Focus mit, was bei wechselnden Lichtverhältnissen
   am Vorratsschrank die Trefferquote steigert.
3. **Spezifikations-Passung:** A15 Bionic (iPhone 13 Pro Max) und iOS 18
   übertreffen alle Mindestanforderungen. Einzelscan, Schutz vor Doppelscans,
   EAN-8/EAN-13, Torch und Haptik lassen sich sauber umsetzen.
4. **Simulator-Strategie:** Für die Entwicklung im Simulator muss ein
   Mock-Scanner vorgesehen werden (z. B. Textfeld oder vordefinierte
   Test-GTINs).
