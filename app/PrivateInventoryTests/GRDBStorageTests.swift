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

    /// The unresolved_scan table refuses negative quantities at the
    /// storage layer (migration 0004, the same never-negative
    /// invariant as stock_level — CodeRabbit finding, ticket #14).
    ///
    /// Given: a migrated database
    /// When: an UnresolvedScan row with quantity -1 is inserted by
    /// raw SQL (bypassing the validated domain model)
    /// Then: the CHECK constraint rejects the insert
    @Test func unresolvedScanQuantityCheckRefusesNegativeRawInsert() throws {
        // Given: a product and the Keller location
        let inventory = try TestInventory()
        let product = try inventory.repository.createProduct(TestInventory.product())
        let cellar = try #require(try inventory.cellar())

        // When/Then: a raw SQL insert with a negative quantity
        #expect(throws: Error.self) {
            try inventory.queue.write { database in
                try database.execute(
                    sql: """
                    INSERT INTO unresolved_scan (id, gtin, locationID, quantity, createdAt)
                    VALUES (?, ?, ?, -1, ?)
                    """,
                    arguments: [
                        UUID().uuidString, product.gtin, cellar.id.uuidString,
                        Date(timeIntervalSince1970: 1_700_000_000)
                    ]
                )
            }
        }
    }

    /// bookUnresolvedScan() books the scan's full quantity and
    /// removes the scan in one transaction.
    ///
    /// Given: a product and a queued scan of 3 units at Keller
    /// When: bookUnresolvedScan(scanID:productID:)
    /// Then: the StockLevel holds 3 units, the scan is gone
    @Test func bookUnresolvedScanBooksFullQuantityAndRemovesScan() throws {
        // Given
        let inventory = try TestInventory()
        let product = try inventory.repository.createProduct(TestInventory.product())
        let cellar = try #require(try inventory.cellar())
        let scan = try inventory.repository.recordUnresolvedScan(
            UnresolvedScan(
                gtin: product.gtin,
                locationID: cellar.id,
                quantity: 3,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )

        // When
        let level = try inventory.repository.bookUnresolvedScan(
            scanID: scan.id,
            productID: product.id
        )

        // Then: the full quantity was booked and the scan is gone
        #expect(level.quantity == 3)
        #expect(try inventory.repository.fetchUnresolvedScans().isEmpty)
    }

    /// bookUnresolvedScan() refuses an already-booked scan: the
    /// atomic booking is the double-booking protection of the queue
    /// resolution (a second run cannot book the same scan again).
    ///
    /// Given: a queued scan of 2 units that was already booked once
    /// When: bookUnresolvedScan is called a second time for it
    /// Then: InventoryError.missingParent is thrown and the StockLevel
    /// still holds exactly the first run's units
    @Test func bookUnresolvedScanRefusesAlreadyBookedScan() throws {
        // Given
        let inventory = try TestInventory()
        let product = try inventory.repository.createProduct(TestInventory.product())
        let cellar = try #require(try inventory.cellar())
        let scan = try inventory.repository.recordUnresolvedScan(
            UnresolvedScan(
                gtin: product.gtin,
                locationID: cellar.id,
                quantity: 2,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
        _ = try inventory.repository.bookUnresolvedScan(
            scanID: scan.id,
            productID: product.id
        )

        // When/Then
        #expect(throws: InventoryError.missingParent) {
            try inventory.repository.bookUnresolvedScan(
                scanID: scan.id,
                productID: product.id
            )
        }

        // And the stock was not doubled
        let stored = try #require(
            try inventory.repository.fetchStockLevel(
                productID: product.id,
                locationID: cellar.id
            )
        )
        #expect(stored.quantity == 2)
    }

    /// bookUnresolvedScan() refuses an unknown product and leaves
    /// the scan in the queue untouched.
    ///
    /// Given: a queued scan but no product
    /// When: bookUnresolvedScan(scanID: productID: unknown)
    /// Then: InventoryError.missingParent is thrown, no StockLevel is
    /// stored, the scan stays in the queue
    @Test func bookUnresolvedScanRefusesUnknownProduct() throws {
        // Given
        let inventory = try TestInventory()
        let cellar = try #require(try inventory.cellar())
        let scan = try inventory.repository.recordUnresolvedScan(
            UnresolvedScan(
                gtin: "0000000000000",
                locationID: cellar.id,
                quantity: 1,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )

        // When/Then
        #expect(throws: InventoryError.missingParent) {
            try inventory.repository.bookUnresolvedScan(
                scanID: scan.id,
                productID: UUID()
            )
        }

        // And the scan is untouched, no StockLevel exists
        #expect(try inventory.repository.fetchUnresolvedScans().count == 1)
        #expect(try inventory.repository.fetchStockLevels(productID: nil).isEmpty)
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
