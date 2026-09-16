import Foundation
import Observation
import UIKit

/// One passive stock hint for another location (scan overlay, ADR-0003).
struct OtherLocationStock: Equatable, Identifiable {
    let locationName: String
    let quantity: Int
    var id: String {
        locationName
    }
}

/// Card content of the scan-result overlay (sheet, ADR-0008).
struct ScanOverlay: Identifiable, Equatable {
    enum Content: Equatable {
        case booked(
            productName: String,
            gtin: String,
            sourceLabelKey: String,
            before: Int,
            after: Int,
            otherStock: [OtherLocationStock]
        )
        case queued(gtin: String)
        case failed
    }

    let id: UUID
    let content: Content

    init(content: Content) {
        id = UUID()
        self.content = content
    }
}

/// All scan-tab state (no UI): session location, camera permission,
/// scan window, result overlay. Booking goes ONLY through
/// `ScanSession.scan` (ADR-0003).
@MainActor
@Observable
final class ScanTabModel {
    enum Phase: Equatable {
        case loading
        case ready
        case noLocations
        case loadFailed(String)
    }

    // MARK: State

    private(set) var phase: Phase = .loading
    private(set) var locations: [Location] = []
    private(set) var sessionLocationID: UUID?
    private(set) var permissionState: CameraPermissionState
    private(set) var isScanning = false
    private(set) var unavailableReason: String?
    /// Settable for the sheet binding (native swipe-down dismiss).
    var overlay: ScanOverlay?

    // MARK: Dependencies

    private let repository: any InventoryRepository
    private let lookup: CatalogLookup
    private let store: SessionLocationStore
    let scanner: any Scanner
    private var session: ScanSession?

    init(
        repository: any InventoryRepository,
        lookup: CatalogLookup,
        store: SessionLocationStore,
        scanner: any Scanner
    ) {
        self.repository = repository
        self.lookup = lookup
        self.store = store
        self.scanner = scanner
        permissionState = scanner.permissionState
    }

    // MARK: Derived state

    var sessionLocation: Location? {
        locations.first { $0.id == sessionLocationID }
    }

    /// Device capable + permission granted (see `Scanner.isAvailable`).
    var scannerIsAvailable: Bool {
        scanner.isAvailable
    }

    /// True for the stub (tests, debug simulator build) — gates the
    /// "Scan simulieren" affordance (D4a).
    var isStubScanner: Bool {
        scanner is ScannerStub
    }

    // MARK: Lifecycle

    /// Loads locations and resolves the session location
    /// (stored preference → "Keller" by name → first).
    func start() {
        do {
            let fetched = try repository.fetchLocations()
            locations = fetched
            guard
                let resolved = ScanSession.resolveSessionLocation(
                    storedID: store.read(),
                    locations: fetched
                )
            else {
                sessionLocationID = nil
                session = nil
                phase = .noLocations
                return
            }
            sessionLocationID = resolved.id
            rebuildSession()
            permissionState = scanner.permissionState
            phase = .ready
        } catch {
            phase = .loadFailed(error.localizedDescription)
        }
    }

    // MARK: Session location

    /// Persists the preference and rebuilds the session. Never per scan
    /// (ADR-0008), but changeable before and during the session.
    func selectLocation(_ id: UUID?) {
        guard let id else { return }
        store.write(id)
        sessionLocationID = id
        rebuildSession()
    }

    private func rebuildSession() {
        session = sessionLocation.map { location in
            ScanSession(
                sessionLocationID: location.id,
                repository: repository,
                lookup: lookup
            )
        }
    }

    // MARK: Camera & scanning

    func requestPermission() async {
        permissionState = await scanner.requestPermission()
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Opens one scan window (ADR-0003: recognition only during an
    /// active window). No-op when no session or no granted permission.
    func startScan() {
        guard
            phase == .ready,
            session != nil,
            permissionState == .granted,
            scanner.isAvailable
        else { return }
        do {
            try scanner.start { [weak self] gtin in
                self?.handleGTIN(gtin)
            }
            isScanning = true
        } catch let error as ScanStartError {
            isScanning = false
            if case let .unavailable(reason) = error {
                unavailableReason = reason
            }
        } catch {
            isScanning = false
            unavailableReason = error.localizedDescription
        }
    }

    /// Debug simulator build only (D4a): opens a window and feeds the
    /// GTIN through the same delivery path as live recognition.
    func simulateScan(gtin: String) {
        guard phase == .ready, session != nil, !isScanning else { return }
        do {
            try scanner.start { [weak self] gtin in
                self?.handleGTIN(gtin)
            }
            isScanning = true
        } catch {
            isScanning = false
            unavailableReason = error.localizedDescription
            return
        }
        scanner.debugSimulateScan(gtin: gtin)
    }

    /// GTIN callback: ends the window, then books via `ScanSession`
    /// (booking goes ONLY through `ScanSession.scan`, ADR-0003).
    private func handleGTIN(_ gtin: String) {
        scanner.stop()
        isScanning = false
        unavailableReason = nil
        guard let session else { return }
        Task {
            do {
                let outcome = try await session.scan(gtin: gtin)
                self.overlay = Self.overlay(for: outcome, model: self)
            } catch {
                self.overlay = ScanOverlay(content: .failed)
            }
        }
    }

    private static func overlay(for outcome: ScanOutcome, model: ScanTabModel) -> ScanOverlay {
        switch outcome {
        case let .booked(product, stockLevel):
            let otherStock = (try? model.repository.fetchStockLevels(productID: product.id))?
                .filter { $0.locationID != stockLevel.locationID }
                .map { level in
                    OtherLocationStock(
                        locationName: model.locationName(for: level.locationID),
                        quantity: level.quantity
                    )
                }
                ?? []
            return ScanOverlay(
                content: .booked(
                    productName: product.name,
                    gtin: product.gtin,
                    sourceLabelKey: sourceLabelKey(for: product.source),
                    before: stockLevel.quantity - 1,
                    after: stockLevel.quantity,
                    otherStock: otherStock
                )
            )
        case let .queued(unresolved):
            return ScanOverlay(content: .queued(gtin: unresolved.gtin))
        }
    }

    private func locationName(for id: UUID) -> String {
        locations.first { $0.id == id }?.name ?? "Unbekannt"
    }

    private static func sourceLabelKey(for source: ProductSource) -> String {
        switch source {
        case .mcp: "dm-Katalog"
        case .search: "dm-Suche"
        case .obf: "OpenFood/BeautyFacts"
        case .manual: "Lokal angelegt"
        }
    }

    // MARK: Overlay actions

    func dismissOverlay() {
        overlay = nil
    }

    /// "Wieder scannen +1" (D5a): dismiss overlay AND immediately start
    /// a new scan window.
    func rescan() {
        overlay = nil
        startScan()
    }
}
