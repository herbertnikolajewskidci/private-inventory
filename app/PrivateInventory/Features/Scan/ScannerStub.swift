import Foundation

/// Deterministic `Scanner` for tests and the debug simulator build
/// (ADR-0006: handwritten stub, no mock framework, no camera).
///
/// Behavior contract (mirrored 1:1 by `ScannerStubTests`):
/// - `start(onGTIN:)` throws when `!isAvailable`; else opens the window
///   and stores the callback. Starting while open replaces the callback
///   and keeps the window.
/// - `debugSimulateScan(gtin:)` delivers exactly once and only while a
///   window is open; the window then closes (stop semantics).
/// - `stop()` closes the window; simulation after stop delivers nothing.
/// - `requestPermission()` awaits and returns `permissionAfterRequest`;
///   `permissionState` equals it afterwards.
@MainActor
final class ScannerStub: Scanner, @unchecked Sendable {
    var isAvailable: Bool
    private(set) var permissionState: CameraPermissionState
    private let permissionAfterRequest: CameraPermissionState

    private var windowIsOpen = false
    private var onGTIN: (@MainActor (String) -> Void)?

    init(
        isAvailable: Bool = true,
        permissionState: CameraPermissionState = .notDetermined,
        permissionAfterRequest: CameraPermissionState = .granted
    ) {
        self.isAvailable = isAvailable
        self.permissionState = permissionState
        self.permissionAfterRequest = permissionAfterRequest
    }

    func requestPermission() async -> CameraPermissionState {
        // Await to mirror the async signature of the live implementation.
        try? await Task.sleep(for: .milliseconds(1))
        permissionState = permissionAfterRequest
        return permissionState
    }

    func start(onGTIN: @escaping @MainActor (String) -> Void) throws {
        guard isAvailable else {
            throw ScanStartError.unavailable(reason: "scanner stub is unavailable")
        }
        // Start while open: replace the callback, keep the window.
        self.onGTIN = onGTIN
        windowIsOpen = true
    }

    func stop() {
        windowIsOpen = false
        onGTIN = nil
    }

    func debugSimulateScan(gtin: String) {
        guard windowIsOpen else { return }
        let callback = onGTIN
        stop()
        callback?(gtin)
    }
}
