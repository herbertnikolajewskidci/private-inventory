import Foundation
@testable import PrivateInventory
import Testing

/// Domain invariants of the UnresolvedScan (ADR-0003): the quantity
/// can never be negative (same pattern as StockLevel, ticket #14
/// CodeRabbit finding).
struct UnresolvedScanTests {
    /// The initializer refuses negative quantities, so the
    /// never-negative invariant holds from construction on.
    ///
    /// Given: the never-negative invariant of an UnresolvedScan
    /// When: an UnresolvedScan is constructed with quantity -1
    /// Then: InventoryError.negativeQuantity is thrown
    @Test func initRefusesNegativeQuantity() {
        // When/Then
        #expect(throws: InventoryError.negativeQuantity) {
            try UnresolvedScan(
                gtin: "4000000000001",
                locationID: UUID(),
                quantity: -1,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        }
    }

    /// Decoding refuses negative quantities as well: a decoded
    /// UnresolvedScan can never represent a negative quantity.
    ///
    /// Given: a JSON payload with quantity -1
    /// When: the payload is decoded into an UnresolvedScan
    /// Then: a DecodingError is thrown
    @Test func decodingRefusesNegativeQuantity() {
        // Given: a payload whose quantity violates the invariant
        let payload = """
        {"id":"11111111-1111-1111-1111-111111111111",\
        "gtin":"4000000000001",\
        "locationID":"33333333-3333-3333-3333-333333333333","quantity":-1,\
        "createdAt":1700000000}
        """

        // When/Then
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(UnresolvedScan.self, from: Data(payload.utf8))
        }
    }
}
