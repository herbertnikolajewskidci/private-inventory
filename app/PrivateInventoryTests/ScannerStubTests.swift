import Foundation
@testable import PrivateInventory
import Testing

@Suite("ScannerStub: deterministic scanner double (ADR-0006, no camera)")
struct ScannerStubTests {
    @Test("debugSimulateScan outside a scan window delivers nothing")
    @MainActor
    func simulateOutsideWindowDeliversNothing() {
        // Given: a stub without an open scan window
        let stub = ScannerStub()
        var delivered: [String] = []

        // When: a GTIN is simulated outside any window
        stub.debugSimulateScan(gtin: "4012345678901")

        // Then: nothing is delivered (no callback was ever registered)
        #expect(delivered.isEmpty)
    }

    @Test("start opens a window; simulateScan delivers exactly one GTIN and ends the window")
    @MainActor
    func startOpensWindowAndSimulationDeliversOnce() throws {
        // Given: an available stub
        let stub = ScannerStub()
        var delivered: [String] = []

        // When: a scan window is opened and a GTIN is simulated
        try stub.start { delivered.append($0) }
        stub.debugSimulateScan(gtin: "4012345678901")

        // Then: exactly one GTIN is delivered
        #expect(delivered == ["4012345678901"])

        // And: the window is ended — a second simulation delivers nothing
        stub.debugSimulateScan(gtin: "4000000000006")
        #expect(delivered == ["4012345678901"])
    }

    @Test("start throws when the stub is unavailable")
    @MainActor
    func startThrowsWhenUnavailable() {
        // Given: an unavailable stub
        let stub = ScannerStub(isAvailable: false)
        var delivered: [String] = []

        // When/Then: starting a scan window throws ScanStartError
        #expect(throws: ScanStartError.unavailable(reason: "scanner stub is unavailable")) {
            try stub.start { delivered.append($0) }
        }
        #expect(delivered.isEmpty)
    }

    @Test("stop closes the open scan window")
    @MainActor
    func stopClosesWindow() throws {
        // Given: an open scan window
        let stub = ScannerStub()
        var delivered: [String] = []
        try stub.start { delivered.append($0) }

        // When: the window is stopped
        stub.stop()

        // Then: simulation after stop delivers nothing
        stub.debugSimulateScan(gtin: "4012345678901")
        #expect(delivered.isEmpty)
    }
}
