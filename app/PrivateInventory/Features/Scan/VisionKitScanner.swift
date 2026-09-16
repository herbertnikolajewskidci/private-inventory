import AVFoundation
import SwiftUI
import Vision
import VisionKit

/// Live barcode scanner backed by VisionKit's `DataScannerViewController`.
///
/// The SwiftUI host (`ScannerHost`) attaches its `DataScannerViewController`
/// to this class. `startScanning()` only works once the controller is in
/// the view hierarchy, so a start request that arrives earlier is buffered
/// and applied on attach.
@MainActor
final class VisionKitScanner: NSObject, Scanner, DataScannerViewControllerDelegate {
    // MARK: Scanner

    var permissionState: CameraPermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    var isAvailable: Bool {
        DataScannerViewController.isAvailable && permissionState == .granted
    }

    func requestPermission() async -> CameraPermissionState {
        _ = await AVCaptureDevice.requestAccess(for: .video)
        return permissionState
    }

    func start(onGTIN: @escaping @MainActor (String) -> Void) throws {
        self.onGTIN = onGTIN
        if let hostController {
            try hostController.startScanning()
        } else {
            // Host not attached yet: buffer the request, applied on attach.
            pendingStart = true
        }
    }

    func stop() {
        pendingStart = false
        onGTIN = nil
        hostController?.stopScanning()
    }

    /// Live implementation is a no-op (ADR-0006): simulation is stub-only.
    func debugSimulateScan(gtin _: String) {}

    // MARK: Host attachment

    /// The `DataScannerViewController` owned by the SwiftUI host.
    private(set) var hostController: DataScannerViewController?
    private var pendingStart = false
    private var onGTIN: (@MainActor (String) -> Void)?

    /// Called by `ScannerHost` when the controller enters the view
    /// hierarchy. Applies a buffered start request.
    ///
    /// - Returns: the buffered start's failure, if applying it failed
    ///   (CodeRabbit: never discard a deferred startup error with
    ///   `try?` — the model already believes the window is open).
    func attachHostController(_ controller: DataScannerViewController) -> ScanStartError? {
        hostController = controller
        controller.delegate = self
        guard pendingStart else { return nil }
        pendingStart = false
        do {
            try controller.startScanning()
            return nil
        } catch let error as ScanStartError {
            onGTIN = nil
            return error
        } catch {
            onGTIN = nil
            return ScanStartError.unavailable(reason: String(describing: error))
        }
    }

    func detachHostController() {
        pendingStart = false
        onGTIN = nil
        hostController = nil
    }

    // MARK: DataScannerViewControllerDelegate

    func dataScanner(
        _: DataScannerViewController,
        didAdd addedItems: [RecognizedItem],
        allItems _: [RecognizedItem]
    ) {
        // First recognized GTIN ends the window.
        for item in addedItems {
            guard case let .barcode(barcode) = item, let payload = barcode.payloadStringValue else {
                continue
            }
            let callback = onGTIN
            stop()
            callback?(payload)
            return
        }
    }
}

/// SwiftUI host that embeds the VisionKit `DataScannerViewController` and
/// attaches it to a `VisionKitScanner`.
@MainActor
struct ScannerHost: UIViewControllerRepresentable {
    let scanner: VisionKitScanner
    /// Deferred startup failure: a buffered start could not be applied
    /// at attach. The model must stop believing the window is open.
    let onStartFailure: (ScanStartError) -> Void

    func makeUIViewController(context _: Context) -> DataScannerViewController {
        // GTINs are EAN barcodes; no QR (CONTEXT.md glossary).
        DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce])],
            qualityLevel: .balanced
        )
    }

    func updateUIViewController(_ controller: DataScannerViewController, context _: Context) {
        if let failure = scanner.attachHostController(controller) {
            onStartFailure(failure)
        }
    }

    @MainActor
    final class Coordinator {
        let scanner: VisionKitScanner

        init(scanner: VisionKitScanner) {
            self.scanner = scanner
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(scanner: scanner)
    }

    static func dismantleUIViewController(
        _: DataScannerViewController,
        coordinator: Coordinator
    ) {
        coordinator.scanner.detachHostController()
    }
}
