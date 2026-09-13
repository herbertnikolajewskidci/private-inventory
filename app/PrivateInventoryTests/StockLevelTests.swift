@testable import PrivateInventory
import XCTest

final class StockLevelTests: XCTestCase {
    /// A new StockLevel starts empty.
    ///
    /// Given: no scans have happened yet
    /// When: a StockLevel is created
    /// Then: its quantity is 0
    func testNewStockLevelHasQuantityZero() {
        // Given: no scans yet
        let stockLevel = StockLevel()

        // When/Then: fresh creation
        XCTAssertEqual(stockLevel.quantity, 0)
    }

    /// One scanIn() increases the quantity by one.
    ///
    /// Given: a new StockLevel with quantity 0
    /// When: scanIn() is called once
    /// Then: quantity is 1
    func testOneScanInIncreasesQuantityToOne() {
        // Given: a new StockLevel with quantity 0
        var stockLevel = StockLevel()

        // When: one scan
        stockLevel.scanIn()

        // Then: quantity increased by one
        XCTAssertEqual(stockLevel.quantity, 1)
    }

    /// Two scanIn() calls increase the quantity by two.
    ///
    /// Given: a new StockLevel with quantity 0
    /// When: scanIn() is called twice
    /// Then: quantity is 2
    func testTwoScanInsIncreaseQuantityToTwo() {
        // Given: a new StockLevel with quantity 0
        var stockLevel = StockLevel()

        // When: two scans
        stockLevel.scanIn()
        stockLevel.scanIn()

        // Then: quantity increased by two
        XCTAssertEqual(stockLevel.quantity, 2)
    }
}
