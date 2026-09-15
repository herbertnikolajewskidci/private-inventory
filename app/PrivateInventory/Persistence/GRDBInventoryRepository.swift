import Foundation
import GRDB

/// The GRDB implementation of `InventoryRepository` (ADR-0005:
/// persistence behind a repository protocol).
///
/// Booking operations (scanIn / withdraw / transfer) reuse the domain
/// logic of `StockLevel`, so the invariants (quantity never negative,
/// transfer preserves the total) hold at the storage layer as well.
struct GRDBInventoryRepository: InventoryRepository {
    private let queue: DatabaseQueue

    init(database: InventoryDatabase) {
        queue = database.queue
    }

    // MARK: - Locations

    func fetchLocations() throws -> [Location] {
        try queue.read { database in
            try Location.order(Column("name").asc).fetchAll(database)
        }
    }

    // MARK: - Products

    func createProduct(_ product: Product) throws -> Product {
        try queue.write { database in
            let existing = try Product
                .filter(Column("gtin") == product.gtin)
                .fetchOne(database)
            guard existing == nil else {
                throw InventoryError.duplicateGTIN
            }
            try product.insert(database)
            return product
        }
    }

    func fetchProduct(gtin: String) throws -> Product? {
        try queue.read { database in
            try Product.filter(Column("gtin") == gtin).fetchOne(database)
        }
    }

    // MARK: - Stock bookings

    func scanIn(productID: UUID, locationID: UUID) throws -> StockLevel {
        try queue.write { database in
            try requireProduct(database, productID)
            try requireLocation(database, locationID)
            var level = try level(database, productID: productID, locationID: locationID)
                ?? StockLevel(productID: productID, locationID: locationID)
            level.scanIn()
            try level.save(database)
            return level
        }
    }

    func withdraw(productID: UUID, locationID: UUID, amount: Int) throws -> StockLevel {
        try queue.write { database in
            guard var level = try level(database, productID: productID, locationID: locationID) else {
                throw InventoryError.insufficientStock
            }
            guard level.withdraw(amount: amount) else {
                throw InventoryError.insufficientStock
            }
            try level.update(database)
            return level
        }
    }

    func transfer(
        productID: UUID,
        fromLocationID: UUID,
        toLocationID: UUID,
        amount: Int
    ) throws -> (source: StockLevel, destination: StockLevel) {
        guard fromLocationID != toLocationID else {
            throw InventoryError.sameLocation
        }
        return try queue.write { database in
            try requireProduct(database, productID)
            try requireLocation(database, fromLocationID)
            try requireLocation(database, toLocationID)
            var source = try level(database, productID: productID, locationID: fromLocationID)
                ?? StockLevel(productID: productID, locationID: fromLocationID)
            var destination = try level(database, productID: productID, locationID: toLocationID)
                ?? StockLevel(productID: productID, locationID: toLocationID)
            guard source.transfer(to: &destination, amount: amount) else {
                throw InventoryError.insufficientStock
            }
            try source.update(database)
            try destination.save(database)
            return (source, destination)
        }
    }

    // MARK: - Stock reads

    func fetchStockLevels(productID: UUID?) throws -> [StockLevel] {
        try queue.read { database in
            if let productID {
                return try StockLevel
                    .filter(Column("productID") == productID.uuidString)
                    .fetchAll(database)
            }
            return try StockLevel.fetchAll(database)
        }
    }

    func fetchStockLevel(productID: UUID, locationID: UUID) throws -> StockLevel? {
        try queue.read { database in
            try level(database, productID: productID, locationID: locationID)
        }
    }

    // MARK: - Unresolved scans

    func fetchUnresolvedScans() throws -> [UnresolvedScan] {
        try queue.read { database in
            try UnresolvedScan.order(Column("createdAt").asc).fetchAll(database)
        }
    }

    func recordUnresolvedScan(_ scan: UnresolvedScan) throws -> UnresolvedScan {
        try queue.write { database in
            try requireLocation(database, scan.locationID)
            try scan.insert(database)
            return scan
        }
    }

    func deleteUnresolvedScan(id: UUID) throws {
        // Deleting a nonexistent id is not an error (0 or 1 rows
        // affected are both success).
        try queue.write { database in
            _ = try UnresolvedScan
                .filter(Column("id") == id.uuidString)
                .deleteAll(database)
        }
    }

    // MARK: - Helpers

    /// The StockLevel for exactly one product and location, if any.
    private func level(_ database: Database, productID: UUID, locationID: UUID) throws -> StockLevel? {
        try StockLevel
            .filter(
                Column("productID") == productID.uuidString
                    && Column("locationID") == locationID.uuidString
            )
            .fetchOne(database)
    }

    // MARK: - Parent validation

    // Foreign keys are disabled in production builds (ADR-0005), so
    // the repository validates referenced parents itself before the
    // writes of scanIn / transfer / recordUnresolvedScan; otherwise
    // dangling references would create orphan rows silently.

    /// Throws `InventoryError.missingParent` when no Product exists
    /// under `id`.
    private func requireProduct(_ database: Database, _ id: UUID) throws {
        guard try Product
            .filter(Column("id") == id.uuidString)
            .fetchOne(database) != nil
        else {
            throw InventoryError.missingParent
        }
    }

    /// Throws `InventoryError.missingParent` when no Location exists
    /// under `id`.
    private func requireLocation(_ database: Database, _ id: UUID) throws {
        guard try Location
            .filter(Column("id") == id.uuidString)
            .fetchOne(database) != nil
        else {
            throw InventoryError.missingParent
        }
    }
}
