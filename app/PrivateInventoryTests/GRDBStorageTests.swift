import Foundation
import GRDB
@testable import PrivateInventory
import Testing

/// Storage integrity at the GRDB layer: UUID identifiers are stored
/// as text (ADR-0005), and booking operations refuse dangling
/// references (foreign keys are disabled in production, ADR-0005).
struct GRDBStorageTests {
    /// UUID identifiers are stored as text, not as blobs (ADR-0005:
    /// sync-capable UUID text keys; the GRDB default is a blob).
    ///
    /// Given: one of every record type is stored
    /// When: the SQLite storage type of every UUID column is
    /// inspected (raw SQL)
    /// Then: every UUID column reports "text"
    @Test func uuidIdentifiersAreStoredAsText() throws {
        // Given: a product, a stock level and an unresolved scan
        let inventory = try TestInventory()
        let product = try inventory.repository.createProduct(TestInventory.product())
        let cellar = try #require(try inventory.cellar())
        _ = try inventory.repository.scanIn(productID: product.id, locationID: cellar.id)
        _ = try inventory.repository.recordUnresolvedScan(
            UnresolvedScan(
                gtin: "0000000000000",
                locationID: cellar.id,
                quantity: 1,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )

        // When: the storage type of every UUID column
        let storageTypes = try inventory.queue.read { database in
            try String.fetchAll(database, sql: """
            SELECT DISTINCT typeof(id) FROM product
            UNION SELECT DISTINCT typeof(id) FROM location
            UNION SELECT DISTINCT typeof(productID) FROM stock_level
            UNION SELECT DISTINCT typeof(locationID) FROM stock_level
            UNION SELECT DISTINCT typeof(id) FROM unresolved_scan
            UNION SELECT DISTINCT typeof(locationID) FROM unresolved_scan
            """)
        }

        // Then: every UUID column is stored as text
        #expect(storageTypes == ["text"])
    }

    /// recordUnresolvedScan() refuses an unknown location.
    ///
    /// Given: a fresh database without that location
    /// When: an UnresolvedScan is recorded for an unknown location
    /// Then: InventoryError.missingParent is thrown and nothing is
    /// stored
    @Test func recordUnresolvedScanRefusesUnknownLocation() throws {
        // Given: a fresh database (the location does not exist)
        let inventory = try TestInventory()

        // When/Then
        #expect(throws: InventoryError.missingParent) {
            try inventory.repository.recordUnresolvedScan(
                UnresolvedScan(
                    gtin: "0000000000000",
                    locationID: UUID(),
                    quantity: 1,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
            )
        }

        // And nothing was stored
        #expect(try inventory.repository.fetchUnresolvedScans().isEmpty)
    }

    /// scanIn() refuses an unknown product.
    ///
    /// Given: a fresh database without that product
    /// When: scanIn(productID: unknown, locationID: Keller)
    /// Then: InventoryError.missingParent is thrown and no
    /// StockLevel row is stored
    @Test func scanInRefusesUnknownProduct() throws {
        // Given
        let inventory = try TestInventory()
        let cellar = try #require(try inventory.cellar())

        // When/Then
        #expect(throws: InventoryError.missingParent) {
            try inventory.repository.scanIn(productID: UUID(), locationID: cellar.id)
        }

        // And nothing was stored
        #expect(try inventory.repository.fetchStockLevels(productID: nil).isEmpty)
    }

    /// scanIn() refuses an unknown location.
    ///
    /// Given: a product, but no matching location
    /// When: scanIn(productID: product, locationID: unknown)
    /// Then: InventoryError.missingParent is thrown and no
    /// StockLevel row is stored
    @Test func scanInRefusesUnknownLocation() throws {
        // Given
        let inventory = try TestInventory()
        let product = try inventory.repository.createProduct(TestInventory.product())

        // When/Then
        #expect(throws: InventoryError.missingParent) {
            try inventory.repository.scanIn(productID: product.id, locationID: UUID())
        }

        // And nothing was stored
        #expect(try inventory.repository.fetchStockLevels(productID: nil).isEmpty)
    }

    /// transfer() refuses unknown locations as well (the parent
    /// validation covers the transfer path too).
    ///
    /// Given: a product with 1 unit at Keller
    /// When: transfer to an unknown destination location
    /// Then: InventoryError.missingParent is thrown, Keller keeps
    /// its unit, no rows are created
    @Test func transferRefusesUnknownLocation() throws {
        // Given
        let inventory = try TestInventory()
        let product = try inventory.repository.createProduct(TestInventory.product())
        let cellar = try #require(try inventory.cellar())
        _ = try inventory.repository.scanIn(productID: product.id, locationID: cellar.id)

        // When/Then
        #expect(throws: InventoryError.missingParent) {
            try inventory.repository.transfer(
                productID: product.id,
                fromLocationID: cellar.id,
                toLocationID: UUID(),
                amount: 1
            )
        }

        // And nothing was changed
        let stored = try #require(
            try inventory.repository.fetchStockLevel(productID: product.id, locationID: cellar.id)
        )
        #expect(stored.quantity == 1)
    }
}
