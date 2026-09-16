import Foundation

/// Read/write access to the inventory: Products, Locations,
/// StockLevels and UnresolvedScans.
///
/// This protocol is the layer boundary (ADR-0007): Features depend
/// on it and never on GRDB. The GRDB implementation lives in
/// `Persistence/`.
protocol InventoryRepository: Sendable {
    /// All locations, including the seeded defaults.
    func fetchLocations() throws -> [Location]

    /// Creates a Product. Throws `InventoryError.duplicateGTIN` when
    /// a Product with the same GTIN already exists.
    func createProduct(_ product: Product) throws -> Product

    /// The product stored under `gtin`, if any. The lookup includes
    /// alias GTINs (ADR-0009).
    func fetchProduct(gtin: String) throws -> Product?

    /// Einbuchen: raises the quantity of the StockLevel for
    /// (productID, locationID) by one. Creates the StockLevel when
    /// it does not exist yet. Throws
    /// `InventoryError.missingParent` when the product or the
    /// location does not exist.
    func scanIn(productID: UUID, locationID: UUID) throws -> StockLevel

    /// Entnehmen: lowers the quantity of the StockLevel for
    /// (productID, locationID) by `amount`. Throws
    /// `InventoryError.insufficientStock` when the quantity would
    /// become negative; the StockLevel is left unchanged then.
    func withdraw(productID: UUID, locationID: UUID, amount: Int) throws -> StockLevel

    /// Verschieben: moves `amount` of the product's stock from one
    /// location to the other; the total quantity is preserved.
    /// Throws `InventoryError.insufficientStock` when the source
    /// quantity is too low, `InventoryError.sameLocation` when
    /// both locations are identical and
    /// `InventoryError.missingParent` when the product or one of
    /// the locations does not exist; nothing is persisted then.
    func transfer(
        productID: UUID,
        fromLocationID: UUID,
        toLocationID: UUID,
        amount: Int
    ) throws -> (source: StockLevel, destination: StockLevel)

    /// StockLevels, optionally restricted to one product.
    func fetchStockLevels(productID: UUID?) throws -> [StockLevel]

    /// The StockLevel for exactly one product and location, if any.
    func fetchStockLevel(productID: UUID, locationID: UUID) throws -> StockLevel?

    /// All UnresolvedScans.
    func fetchUnresolvedScans() throws -> [UnresolvedScan]

    /// Stores an UnresolvedScan (a GTIN that no source could resolve
    /// yet). Throws `InventoryError.missingParent` when the location
    /// does not exist.
    func recordUnresolvedScan(_ scan: UnresolvedScan) throws -> UnresolvedScan

    /// Removes an UnresolvedScan from the queue (after it was
    /// resolved and booked, ticket #14). Deleting an unknown id is
    /// not an error.
    func deleteUnresolvedScan(id: UUID) throws

    /// Binds an additional GTIN to a product (ADR-0009). Throws
    /// `InventoryError.duplicateGTIN` when `gtin` is the primary GTIN of
    /// a Product or an alias of a different one; `missingParent` when
    /// the product does not exist (the repository validates parents
    /// itself, ADR-0005). Creating the same alias twice is a no-op.
    func createGTINAlias(gtin: String, productID: UUID) throws

    /// The full binding of a scanned (unresolvable) GTIN in ONE
    /// transaction (ticket #24, CodeRabbit: separate transactions
    /// for product creation, alias creation and the row bookings
    /// could commit product + alias while a later row booking
    /// fails — partial state). Creates the target product when
    /// missing (`product.gtin` free, primary OR alias → reuse),
    /// binds `scannedGTIN` as an alias when it differs from the
    /// target's own GTIN, then books and removes ALL open queue
    /// rows of `scannedGTIN` (per row at its own location).
    ///
    /// Throws `InventoryError.duplicateGTIN` when the target GTIN
    /// is taken by a different product, or `scannedGTIN` is the
    /// primary GTIN of / alias of a different product; atomic:
    /// either the full binding (product, alias, all rows) commits
    /// or nothing does.
    ///
    /// - Returns: the product the scanned GTIN now resolves to,
    ///   and the number of queue rows booked in this run.
    func bindGTIN(scannedGTIN: String, product: Product) throws -> (
        product: Product,
        bookedRows: Int
    )

    /// Einbuchen for a queued UnresolvedScan (ticket #14): books the
    /// scan's full quantity at the scan's location in the StockLevel
    /// of `productID` (creating it when missing), then removes the
    /// scan from the queue — all in ONE transaction, so a scan is
    /// either fully booked and gone, or untouched (never partially
    /// booked; a retry cannot double-book).
    ///
    /// Throws `InventoryError.missingParent` when the product does
    /// not exist or the scan was already booked and removed (e.g.
    /// by a concurrent queue run). Concurrent runs are serialized by
    /// the store: each run re-verifies inside its transaction that
    /// the scan still exists.
    func bookUnresolvedScan(scanID: UUID, productID: UUID) throws -> StockLevel
}
