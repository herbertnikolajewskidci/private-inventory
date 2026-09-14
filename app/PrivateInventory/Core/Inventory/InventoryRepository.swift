import Foundation

/// Read/write access to the inventory: Products, Locations,
/// StockLevels and UnresolvedScans.
///
/// This protocol is the layer boundary (ADR-0007): Features depend
/// on it and never on GRDB. The GRDB implementation lives in
/// `Persistence/`.
protocol InventoryRepository {
    /// All locations, including the seeded defaults.
    func fetchLocations() throws -> [Location]

    /// Creates a Product. Throws `InventoryError.duplicateGTIN` when
    /// a Product with the same GTIN already exists.
    func createProduct(_ product: Product) throws -> Product

    /// The product stored under `gtin`, if any.
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
}
