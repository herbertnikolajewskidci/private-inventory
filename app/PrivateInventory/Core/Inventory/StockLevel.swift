import Foundation

/// The quantity of one Product at one Location.
///
/// A StockLevel is one "Product × Location" pair; the store holds at
/// most one StockLevel per pair (unique constraint, ADR-0003).
struct StockLevel: Identifiable, Equatable, Codable {
    /// Sync-capable identity: a UUID stored as text (ADR-0005).
    let id: UUID
    /// The Product this level belongs to.
    let productID: UUID
    /// The Location this level belongs to.
    let locationID: UUID
    /// The quantity on hand. Invariant: never negative.
    private(set) var quantity: Int

    init(
        id: UUID = UUID(),
        productID: UUID,
        locationID: UUID,
        quantity: Int = 0
    ) {
        self.id = id
        self.productID = productID
        self.locationID = locationID
        self.quantity = quantity
    }

    /// Einbuchen (scanIn): raise the quantity by one per scan
    /// (Supermarkt-Kassen-Prinzip, CONTEXT.md).
    mutating func scanIn() {
        quantity += 1
    }

    /// Entnehmen (withdraw): lower the quantity by `amount`.
    ///
    /// The quantity never goes negative: if `amount` is not positive
    /// or exceeds the current quantity, the quantity is left
    /// unchanged and `false` is returned.
    mutating func withdraw(amount: Int) -> Bool {
        guard amount > 0, quantity >= amount else { return false }
        quantity -= amount
        return true
    }

    /// Verschieben (transfer): move `amount` from this StockLevel to
    /// `destination`.
    ///
    /// Invariants: the total quantity of both levels is preserved and
    /// this level never goes negative. If `amount` is not positive or
    /// exceeds this level's quantity, nothing is moved and `false` is
    /// returned. `destination` must belong to the same Product (the
    /// repository enforces this).
    mutating func transfer(to destination: inout StockLevel, amount: Int) -> Bool {
        guard amount > 0, quantity >= amount else { return false }
        quantity -= amount
        destination.quantity += amount
        return true
    }
}
