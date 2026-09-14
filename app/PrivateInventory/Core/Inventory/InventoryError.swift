/// Errors thrown by inventory booking operations.
enum InventoryError: Error, Equatable {
    /// The requested amount exceeds the available quantity of a
    /// StockLevel. withdraw() and transfer() never let a quantity go
    /// negative.
    case insufficientStock
    /// A Product with the same GTIN already exists. The GTIN is the
    /// unique domain key of a Product.
    case duplicateGTIN
    /// transfer() was called with the same source and destination
    /// location.
    case sameLocation
}
