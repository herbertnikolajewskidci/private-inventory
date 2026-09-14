import Foundation
@testable import PrivateInventory
import Testing

/// Booking logic of a StockLevel (domain level, no database).
struct StockLevelTests {
    /// Test data: one product, two locations.
    let productID = UUID()
    let locationA = UUID()
    let locationB = UUID()

    /// A new StockLevel starts empty.
    ///
    /// Given: no scans have happened yet
    /// When: a StockLevel is created
    /// Then: its quantity is 0
    @Test func newStockLevelHasQuantityZero() throws {
        // Given: no scans yet
        let stockLevel = try StockLevel(productID: productID, locationID: locationA)

        // When/Then: fresh creation
        #expect(stockLevel.quantity == 0)
    }

    /// One scanIn() increases the quantity by one.
    ///
    /// Given: a new StockLevel with quantity 0
    /// When: scanIn() is called once
    /// Then: quantity is 1
    @Test func oneScanInIncreasesQuantityToOne() throws {
        // Given: a new StockLevel with quantity 0
        var stockLevel = try StockLevel(productID: productID, locationID: locationA)

        // When: one scan
        stockLevel.scanIn()

        // Then: quantity increased by one
        #expect(stockLevel.quantity == 1)
    }

    /// Two scanIn() calls increase the quantity by two.
    ///
    /// Given: a new StockLevel with quantity 0
    /// When: scanIn() is called twice
    /// Then: quantity is 2
    @Test func twoScanInsIncreaseQuantityToTwo() throws {
        // Given: a new StockLevel with quantity 0
        var stockLevel = try StockLevel(productID: productID, locationID: locationA)

        // When: two scans
        stockLevel.scanIn()
        stockLevel.scanIn()

        // Then: quantity increased by two
        #expect(stockLevel.quantity == 2)
    }

    /// withdraw() lowers the quantity by the requested amount.
    ///
    /// Given: a StockLevel with quantity 5
    /// When: withdraw(amount: 2)
    /// Then: the withdrawal succeeded and quantity is 3
    @Test func withdrawLowersQuantity() throws {
        // Given: a StockLevel with quantity 5
        var stockLevel = try StockLevel(productID: productID, locationID: locationA, quantity: 5)

        // When: two units are withdrawn
        let withdrew = stockLevel.withdraw(amount: 2)

        // Then
        #expect(withdrew)
        #expect(stockLevel.quantity == 3)
    }

    /// The quantity never goes negative: withdrawing more than
    /// available is refused and leaves the quantity unchanged.
    ///
    /// Given: a StockLevel with quantity 2
    /// When: withdraw(amount: 5)
    /// Then: the withdrawal is refused and quantity stays 2
    @Test func withdrawNeverMakesQuantityNegative() throws {
        // Given: a StockLevel with quantity 2
        var stockLevel = try StockLevel(productID: productID, locationID: locationA, quantity: 2)

        // When: more is withdrawn than is available
        let withdrew = stockLevel.withdraw(amount: 5)

        // Then: refused, quantity unchanged
        #expect(!withdrew)
        #expect(stockLevel.quantity == 2)
    }

    /// withdraw() refuses zero and negative amounts.
    ///
    /// Given: a StockLevel with quantity 1
    /// When: withdraw(amount: 0) and withdraw(amount: -1)
    /// Then: both are refused and the quantity stays 1
    @Test func withdrawRefusesZeroAndNegativeAmounts() throws {
        // Given: a StockLevel with quantity 1
        var stockLevel = try StockLevel(productID: productID, locationID: locationA, quantity: 1)

        // When: zero and a negative amount
        let zeroWithdrawn = stockLevel.withdraw(amount: 0)
        let negativeWithdrawn = stockLevel.withdraw(amount: -1)

        // Then
        #expect(!zeroWithdrawn)
        #expect(!negativeWithdrawn)
        #expect(stockLevel.quantity == 1)
    }

    /// transfer() moves the amount and preserves the total quantity.
    ///
    /// Given: two StockLevels of the same product: source 3,
    /// destination 2 (total 5)
    /// When: transfer(to: destination, amount: 2)
    /// Then: source is 1, destination is 4, total stays 5
    @Test func transferMovesAmountAndPreservesTotal() throws {
        // Given
        var source = try StockLevel(productID: productID, locationID: locationA, quantity: 3)
        var destination = try StockLevel(productID: productID, locationID: locationB, quantity: 2)

        // When: two units move from source to destination
        let moved = source.transfer(to: &destination, amount: 2)

        // Then
        #expect(moved)
        #expect(source.quantity == 1)
        #expect(destination.quantity == 4)
        #expect(source.quantity + destination.quantity == 5)
    }

    /// transfer() can never make the source quantity negative.
    ///
    /// Given: source 1, destination 0
    /// When: transfer(to: destination, amount: 2)
    /// Then: refused; both quantities unchanged, total preserved
    @Test func transferNeverMakesSourceNegative() throws {
        // Given
        var source = try StockLevel(productID: productID, locationID: locationA, quantity: 1)
        var destination = try StockLevel(productID: productID, locationID: locationB, quantity: 0)

        // When: more is transferred than the source holds
        let moved = source.transfer(to: &destination, amount: 2)

        // Then: refused, both unchanged
        #expect(!moved)
        #expect(source.quantity == 1)
        #expect(destination.quantity == 0)
    }

    /// Invariant over a sequence: after any mix of successful and
    /// refused transfers, the total quantity never changes and no
    /// level goes negative.
    ///
    /// Given: two StockLevels with a known total (7 + 4 = 11)
    /// When: a fixed sequence of transfer attempts in both directions
    /// Then: the total is still 11 and both quantities are >= 0
    @Test func transferSequencesPreserveTotalQuantity() throws {
        // Given
        var source = try StockLevel(productID: productID, locationID: locationA, quantity: 7)
        var destination = try StockLevel(productID: productID, locationID: locationB, quantity: 4)
        let total = source.quantity + destination.quantity

        // When: transfers in both directions, one of them too large
        _ = source.transfer(to: &destination, amount: 3)
        _ = destination.transfer(to: &source, amount: 2)
        _ = source.transfer(to: &destination, amount: 99)
        _ = destination.transfer(to: &source, amount: 1)

        // Then
        #expect(source.quantity + destination.quantity == total)
        #expect(source.quantity >= 0)
        #expect(destination.quantity >= 0)
    }

    /// A StockLevel can never represent a negative quantity: the
    /// initializer refuses negative values, so the never-negative
    /// invariant holds from construction on.
    ///
    /// Given: the never-negative invariant of a StockLevel
    /// When: a StockLevel is constructed with quantity -1
    /// Then: InventoryError.negativeQuantity is thrown
    @Test func initRefusesNegativeQuantity() {
        // When/Then
        #expect(throws: InventoryError.negativeQuantity) {
            try StockLevel(productID: productID, locationID: locationA, quantity: -1)
        }
    }

    /// Decoding refuses negative quantities as well: a decoded
    /// StockLevel can never represent negative stock.
    ///
    /// Given: a JSON payload with quantity -1
    /// When: the payload is decoded into a StockLevel
    /// Then: a DecodingError is thrown
    @Test func decodingRefusesNegativeQuantity() {
        // Given: a payload whose quantity violates the invariant
        let payload = """
        {"id":"11111111-1111-1111-1111-111111111111",\
        "productID":"22222222-2222-2222-2222-222222222222",\
        "locationID":"33333333-3333-3333-3333-333333333333","quantity":-1}
        """

        // When/Then
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(StockLevel.self, from: Data(payload.utf8))
        }
    }
}
