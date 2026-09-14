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
    ) throws {
        // The never-negative invariant holds from construction on:
        // a StockLevel can never represent negative stock.
        guard quantity >= 0 else {
            throw InventoryError.negativeQuantity
        }
        self.id = id
        self.productID = productID
        self.locationID = locationID
        self.quantity = quantity
    }

    /// Codable decoding validates the quantity as well, so a
    /// decoded StockLevel cannot represent negative stock (the
    /// database has the same CHECK constraint, ADR-0003).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        productID = try container.decode(UUID.self, forKey: .productID)
        locationID = try container.decode(UUID.self, forKey: .locationID)
        let decodedQuantity = try container.decode(Int.self, forKey: .quantity)
        guard decodedQuantity >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .quantity,
                in: container,
                debugDescription: "StockLevel quantity must not be negative"
            )
        }
        quantity = decodedQuantity
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
