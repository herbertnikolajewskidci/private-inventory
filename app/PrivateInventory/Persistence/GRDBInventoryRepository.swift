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
            // A GTIN that is already an alias of a product can never
            // become a primary GTIN (ADR-0009).
            let aliased = try GTINAlias
                .filter(Column("gtin") == product.gtin)
                .fetchOne(database)
            guard aliased == nil else {
                throw InventoryError.duplicateGTIN
            }
            try product.insert(database)
            return product
        }
    }

    func fetchProduct(gtin: String) throws -> Product? {
        try queue.read { database in
            let product = try Product.filter(Column("gtin") == gtin).fetchOne(database)
            guard let product else {
                // Alias GTINs (ADR-0009): the scanned barcode belongs
                // to the product it is bound to.
                let alias = try GTINAlias.filter(Column("gtin") == gtin).fetchOne(database)
                guard let alias else { return nil }
                return try Product
                    .filter(Column("id") == alias.productID.uuidString)
                    .fetchOne(database)
            }
            return product
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

    func bookUnresolvedScan(scanID: UUID, productID: UUID) throws -> StockLevel {
        try queue.write { database in
            // The scan must still exist: a concurrent queue run may
            // have already booked and removed it. Everything below
            // (book + delete) commits as ONE transaction.
            guard let scan = try UnresolvedScan
                .filter(Column("id") == scanID.uuidString)
                .fetchOne(database)
            else {
                throw InventoryError.missingParent
            }
            try requireProduct(database, productID)

            var level = try level(database, productID: productID, locationID: scan.locationID)
                ?? StockLevel(productID: productID, locationID: scan.locationID)
            for _ in 0 ..< scan.quantity {
                level.scanIn()
            }
            try level.save(database)

            try scan.delete(database)
            return level
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

// MARK: - GTIN aliases + binding (ADR-0009)

// Separate extension (same file, so the private helpers of the
// struct stay visible): keeps the struct body within the
// SwiftLint type-body limit while the alias logic stays together.

extension GRDBInventoryRepository {
    func createGTINAlias(gtin: String, productID: UUID) throws {
        try queue.write { database in
            try requireProduct(database, productID)
            // A primary GTIN is never an alias (ADR-0009).
            let primary = try Product.filter(Column("gtin") == gtin).fetchOne(database)
            guard primary == nil else {
                throw InventoryError.duplicateGTIN
            }
            let alias = try GTINAlias.filter(Column("gtin") == gtin).fetchOne(database)
            if let alias {
                // The same alias twice is a no-op; a different
                // product owns the GTIN already.
                guard alias.productID != productID else { return }
                throw InventoryError.duplicateGTIN
            }
            try GTINAlias(gtin: gtin, productID: productID).insert(database)
        }
    }

    func bindGTIN(scannedGTIN: String, product: Product) throws -> (
        product: Product,
        bookedRows: Int
    ) {
        try queue.write { database in
            let target = try targetProduct(database, requested: product)
            try bindScannedGTIN(database, scannedGTIN: scannedGTIN, target: target)
            let rows = try UnresolvedScan
                .filter(Column("gtin") == scannedGTIN)
                .order(Column("createdAt").asc)
                .fetchAll(database)
            for scan in rows {
                try bookAndDelete(database, scan: scan, productID: target.id)
            }
            return (target, rows.count)
        }
    }

    /// Create-or-reuse of the binding's target product (within the
    /// open transaction of `bindGTIN`): a fresh primary GTIN is
    /// inserted, an existing primary is reused, and a target GTIN
    /// that is already an ALIAS of a product reuses THAT product
    /// (alias-aware reuse, ADR-0009).
    private func targetProduct(_ database: Database, requested product: Product) throws -> Product {
        if let primary = try Product.filter(Column("gtin") == product.gtin).fetchOne(database) {
            return primary
        }
        let aliased = try GTINAlias
            .filter(Column("gtin") == product.gtin)
            .fetchOne(database)
        if let aliased {
            guard let aliasedProduct = try Product
                .filter(Column("id") == aliased.productID.uuidString)
                .fetchOne(database)
            else {
                // Defensive: a dangling alias (the repository
                // validates parents itself, ADR-0005).
                throw InventoryError.missingParent
            }
            return aliasedProduct
        }
        try product.insert(database)
        return product
    }

    /// The scanned GTIN becomes an alias of the target when it
    /// differs (ADR-0009); a primary/alias owned by a DIFFERENT
    /// product is refused (within the open transaction of
    /// `bindGTIN`).
    private func bindScannedGTIN(_ database: Database, scannedGTIN: String, target: Product) throws {
        guard target.gtin != scannedGTIN else { return }
        let scannedPrimary = try Product
            .filter(Column("gtin") == scannedGTIN)
            .fetchOne(database)
        guard scannedPrimary == nil else {
            throw InventoryError.duplicateGTIN
        }
        if let alias = try GTINAlias.filter(Column("gtin") == scannedGTIN).fetchOne(database) {
            // The same binding twice is a no-op; a binding to a
            // different product is refused.
            guard alias.productID == target.id else {
                throw InventoryError.duplicateGTIN
            }
        } else {
            try GTINAlias(gtin: scannedGTIN, productID: target.id)
                .insert(database)
        }
    }

    /// Einbuchen of ONE queued row for the binding (within the open
    /// transaction of `bindGTIN`): books the scan's full quantity at
    /// the scan's location, then removes the scan — the
    /// `bookUnresolvedScan` pattern.
    private func bookAndDelete(_ database: Database, scan: UnresolvedScan, productID: UUID) throws {
        var level = try level(
            database,
            productID: productID,
            locationID: scan.locationID
        ) ?? StockLevel(
            productID: productID,
            locationID: scan.locationID
        )
        for _ in 0 ..< scan.quantity {
            level.scanIn()
        }
        try level.save(database)
        try scan.delete(database)
    }
}
