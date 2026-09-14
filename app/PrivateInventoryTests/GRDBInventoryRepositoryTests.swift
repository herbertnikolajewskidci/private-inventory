import Foundation
import GRDB
@testable import PrivateInventory
import Testing

/// The GRDB repository: persistence round-trips and the booking
/// invariants at the storage layer.
struct GRDBInventoryRepositoryTests {
    // MARK: - Locations

    /// The repository reads the seeded default locations.
    ///
    /// Given: a fresh database
    /// When: fetchLocations()
    /// Then: Keller and Vorratsschrank come back
    @Test func fetchLocationsReturnsSeededDefaults() throws {
        // Given: a fresh database
        let inventory = try TestInventory()

        // When
        let names = try inventory.repository.fetchLocations().map(\.name)

        // Then
        #expect(names.contains("Keller"))
        #expect(names.contains("Vorratsschrank"))
    }

    // MARK: - Products

    /// createProduct() stores a product; fetchProduct(gtin:) reads it
    /// back unchanged (round-trip).
    ///
    /// Given: a fresh database
    /// When: a Product is created and fetched by its GTIN
    /// Then: all fields are unchanged
    @Test func createProductRoundTrips() throws {
        // Given: a fresh database
        let inventory = try TestInventory()
        let created = try inventory.repository.createProduct(TestInventory.product())

        // When: fetched back by its GTIN
        let fetched = try #require(try inventory.repository.fetchProduct(gtin: "4000000000001"))

        // Then: all fields unchanged
        #expect(fetched == created)
    }

    /// createProduct() refuses a duplicate GTIN.
    ///
    /// Given: a product with GTIN 4000000000001 stored
    /// When: another product with the same GTIN is created
    /// Then: InventoryError.duplicateGTIN is thrown
    @Test func createProductRefusesDuplicateGTIN() throws {
        // Given
        let inventory = try TestInventory()
        _ = try inventory.repository.createProduct(TestInventory.product())

        // When/Then
        #expect(throws: InventoryError.duplicateGTIN) {
            try inventory.repository.createProduct(TestInventory.product())
        }
    }

    // MARK: - Stock bookings (scanIn / withdraw / transfer)

    /// scanIn() creates a StockLevel when needed and raises the
    /// quantity by one per scan (round-trip through the database).
    ///
    /// Given: a fresh database with one product and the Keller
    /// location
    /// When: three scans are recorded
    /// Then: the stored StockLevel has quantity 3
    @Test func scanInCreatesStockLevelAndIncreasesQuantity() throws {
        // Given
        let inventory = try TestInventory()
        let product = try inventory.repository.createProduct(TestInventory.product())
        let cellar = try #require(try cellar(of: inventory))

        // When: three scans
        for _ in 0 ..< 3 {
            _ = try inventory.repository.scanIn(productID: product.id, locationID: cellar.id)
        }

        // Then: the stored StockLevel has quantity 3
        let level = try #require(
            try inventory.repository.fetchStockLevel(productID: product.id, locationID: cellar.id)
        )
        #expect(level.quantity == 3)
    }

    /// withdraw() lowers the stored quantity.
    ///
    /// Given: a StockLevel with quantity 3 (from three scans)
    /// When: withdraw(amount: 1)
    /// Then: the returned and the stored StockLevel have quantity 2
    @Test func withdrawDecreasesStoredQuantity() throws {
        // Given
        let inventory = try TestInventory()
        let product = try inventory.repository.createProduct(TestInventory.product())
        let cellar = try #require(try cellar(of: inventory))
        for _ in 0 ..< 3 {
            _ = try inventory.repository.scanIn(productID: product.id, locationID: cellar.id)
        }

        // When
        let level = try inventory.repository.withdraw(
            productID: product.id, locationID: cellar.id, amount: 1
        )

        // Then: in memory and in the database
        #expect(level.quantity == 2)
        let stored = try #require(
            try inventory.repository.fetchStockLevel(productID: product.id, locationID: cellar.id)
        )
        #expect(stored.quantity == 2)
    }

    /// withdraw() can never make a stored quantity negative.
    ///
    /// Given: a StockLevel with quantity 1
    /// When: withdraw(amount: 5)
    /// Then: InventoryError.insufficientStock is thrown and the
    /// stored quantity is still 1
    @Test func withdrawNeverMakesStoredQuantityNegative() throws {
        // Given
        let inventory = try TestInventory()
        let product = try inventory.repository.createProduct(TestInventory.product())
        let cellar = try #require(try cellar(of: inventory))
        _ = try inventory.repository.scanIn(productID: product.id, locationID: cellar.id)

        // When/Then: withdrawing more than available is refused
        #expect(throws: InventoryError.insufficientStock) {
            try inventory.repository.withdraw(
                productID: product.id, locationID: cellar.id, amount: 5
            )
        }

        // And the stored quantity is unchanged
        let stored = try #require(
            try inventory.repository.fetchStockLevel(productID: product.id, locationID: cellar.id)
        )
        #expect(stored.quantity == 1)
    }

    /// transfer() moves a quantity between locations and preserves
    /// the total (round-trip through the database).
    ///
    /// Given: 3 units of a product at Keller, 2 at Vorratsschrank
    /// (total 5)
    /// When: transfer(amount: 2) from Keller to Vorratsschrank
    /// Then: Keller has 1, Vorratsschrank has 4, total stays 5
    @Test func transferMovesQuantityBetweenLocations() throws {
        // Given
        let inventory = try TestInventory()
        let product = try inventory.repository.createProduct(TestInventory.product())
        let cellar = try #require(try cellar(of: inventory))
        let pantry = try #require(try pantry(of: inventory))
        for _ in 0 ..< 3 {
            _ = try inventory.repository.scanIn(productID: product.id, locationID: cellar.id)
        }
        for _ in 0 ..< 2 {
            _ = try inventory.repository.scanIn(productID: product.id, locationID: pantry.id)
        }

        // When: two units move from Keller to Vorratsschrank
        let result = try inventory.repository.transfer(
            productID: product.id,
            fromLocationID: cellar.id,
            toLocationID: pantry.id,
            amount: 2
        )

        // Then: both levels, read back from the database
        let storedSource = try #require(
            try inventory.repository.fetchStockLevel(productID: product.id, locationID: cellar.id)
        )
        let storedDestination = try #require(
            try inventory.repository.fetchStockLevel(productID: product.id, locationID: pantry.id)
        )
        #expect(result.source.quantity == 1)
        #expect(result.destination.quantity == 4)
        #expect(storedSource.quantity == 1)
        #expect(storedDestination.quantity == 4)
        #expect(storedSource.quantity + storedDestination.quantity == 5)
    }

    /// transfer() refuses to move more than is available; nothing is
    /// persisted then.
    ///
    /// Given: 1 unit at Keller, none at Vorratsschrank
    /// When: transfer(amount: 2) from Keller to Vorratsschrank
    /// Then: InventoryError.insufficientStock is thrown, Keller
    /// still has 1, Vorratsschrank still has no StockLevel
    @Test func transferRefusesWhenSourceQuantityTooLow() throws {
        // Given
        let inventory = try TestInventory()
        let product = try inventory.repository.createProduct(TestInventory.product())
        let cellar = try #require(try cellar(of: inventory))
        let pantry = try #require(try pantry(of: inventory))
        _ = try inventory.repository.scanIn(productID: product.id, locationID: cellar.id)

        // When/Then: moving more than available is refused
        #expect(throws: InventoryError.insufficientStock) {
            try inventory.repository.transfer(
                productID: product.id,
                fromLocationID: cellar.id,
                toLocationID: pantry.id,
                amount: 2
            )
        }

        // And nothing was persisted
        let storedSource = try #require(
            try inventory.repository.fetchStockLevel(productID: product.id, locationID: cellar.id)
        )
        #expect(storedSource.quantity == 1)
        let storedDestination = try inventory.repository.fetchStockLevel(
            productID: product.id, locationID: pantry.id
        )
        #expect(storedDestination == nil)
    }

    /// transfer() refuses a transfer to the same location.
    ///
    /// Given: a product with stock at Keller
    /// When: transfer from Keller to Keller
    /// Then: InventoryError.sameLocation is thrown
    @Test func transferRefusesSameLocation() throws {
        // Given
        let inventory = try TestInventory()
        let product = try inventory.repository.createProduct(TestInventory.product())
        let cellar = try #require(try cellar(of: inventory))
        _ = try inventory.repository.scanIn(productID: product.id, locationID: cellar.id)

        // When/Then
        #expect(throws: InventoryError.sameLocation) {
            try inventory.repository.transfer(
                productID: product.id,
                fromLocationID: cellar.id,
                toLocationID: cellar.id,
                amount: 1
            )
        }
    }

    // MARK: - Stock reads

    /// fetchStockLevels() returns all levels; with a productID filter
    /// only that product's levels.
    ///
    /// Given: two products with stock at Keller (2 and 1 units)
    /// When: fetchStockLevels() and fetchStockLevels(productID:)
    /// Then: two levels in total, one for the requested product
    @Test func fetchStockLevelsFiltersByProduct() throws {
        // Given
        let inventory = try TestInventory()
        let mehl = try inventory.repository.createProduct(TestInventory.product())
        let quark = try inventory.repository.createProduct(
            TestInventory.product(gtin: "4000000000002", name: "Quark")
        )
        let cellar = try #require(try cellar(of: inventory))
        for _ in 0 ..< 2 {
            _ = try inventory.repository.scanIn(productID: mehl.id, locationID: cellar.id)
        }
        _ = try inventory.repository.scanIn(productID: quark.id, locationID: cellar.id)

        // When
        let all = try inventory.repository.fetchStockLevels(productID: nil)
        let mehlLevels = try inventory.repository.fetchStockLevels(productID: mehl.id)

        // Then
        #expect(all.count == 2)
        #expect(mehlLevels.count == 1)
        #expect(mehlLevels.first?.quantity == 2)
    }

    // MARK: - Unresolved scans

    /// recordUnresolvedScan() stores a scan; fetchUnresolvedScans()
    /// reads it back unchanged (round-trip).
    ///
    /// Given: a fresh database
    /// When: an UnresolvedScan is recorded and fetched
    /// Then: all fields are unchanged (the timestamp uses whole
    /// seconds, which the database stores exactly)
    @Test func unresolvedScanRoundTrips() throws {
        // Given
        let inventory = try TestInventory()
        let cellar = try #require(try cellar(of: inventory))
        let recorded = try inventory.repository.recordUnresolvedScan(
            UnresolvedScan(
                gtin: "0000000000000",
                locationID: cellar.id,
                quantity: 1,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )

        // When: fetched back
        let scans = try inventory.repository.fetchUnresolvedScans()

        // Then: exactly one scan, all fields unchanged
        #expect(scans.count == 1)
        #expect(scans.first == recorded)
    }

    // MARK: - Helpers

    /// The seeded default location "Keller".
    private func cellar(of inventory: TestInventory) throws -> Location? {
        try inventory.repository.fetchLocations().first { $0.name == "Keller" }
    }

    /// The seeded default location "Vorratsschrank".
    private func pantry(of inventory: TestInventory) throws -> Location? {
        try inventory.repository.fetchLocations().first { $0.name == "Vorratsschrank" }
    }
}
