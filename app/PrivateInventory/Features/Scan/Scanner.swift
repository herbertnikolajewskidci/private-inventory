import Foundation

/// Camera permission state as exposed by the `Scanner` abstraction.
enum CameraPermissionState: Equatable {
    case notDetermined
    case denied
    case granted
}

/// Error thrown when a scan window cannot be started.
enum ScanStartError: Error, Equatable {
    case unavailable(reason: String)
}

/// Abstraction over one live barcode-scanning backend (VisionKit) or a
/// deterministic stub (tests, simulator). A "scan window" is opened by
/// `start(onGTIN:)` and ends with the first recognized GTIN or `stop()`.
///
/// The module-level name intentionally shadows Foundation's `Scanner`
/// (ADR-0006 canon; the repo never uses Foundation's Scanner).
@MainActor protocol Scanner: AnyObject {
    /// Current camera permission state.
    var permissionState: CameraPermissionState { get }

    /// Scanning can start (device capable + permission granted).
    var isAvailable: Bool { get }

    /// Runs the camera permission request; returns the resulting state.
    @MainActor func requestPermission() async -> CameraPermissionState

    /// Opens one scan window; the first recognized GTIN is delivered via
    /// the callback and the window ends. Throws when scanning cannot start.
    @MainActor func start(onGTIN: @escaping @MainActor (String) -> Void) throws

    /// Ends the current window (no-op when none is open).
    func stop()

    /// Feeds a GTIN through the same delivery path as live recognition.
    /// Stub-only (tests/simulator, ADR-0006); live implementation: no-op.
    func debugSimulateScan(gtin: String)
}
