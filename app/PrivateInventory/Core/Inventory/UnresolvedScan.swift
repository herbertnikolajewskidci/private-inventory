import Foundation

/// A scanned GTIN that no local or external source could resolve.
///
/// Stored as soon as it is scanned; resolved later when the network
/// becomes available (lookup chain, ticket #14).
struct UnresolvedScan: Identifiable, Equatable, Codable {
    /// Sync-capable identity: a UUID stored as text (ADR-0005).
    let id: UUID
    var gtin: String
    /// The Location the scan happened at.
    let locationID: UUID
    /// The units the scan books when the GTIN resolves. Invariant:
    /// never negative.
    private(set) var quantity: Int
    /// When the scan happened.
    let createdAt: Date

    init(
        id: UUID = UUID(),
        gtin: String,
        locationID: UUID,
        quantity: Int,
        createdAt: Date
    ) throws {
        // The never-negative invariant holds from construction on
        // (same pattern as StockLevel): the queue resolution books
        // this quantity per unit, and a negative value would trap
        // the booking range.
        guard quantity >= 0 else {
            throw InventoryError.negativeQuantity
        }
        self.id = id
        self.gtin = gtin
        self.locationID = locationID
        self.quantity = quantity
        self.createdAt = createdAt
    }

    /// Codable decoding validates the quantity as well, so a decoded
    /// UnresolvedScan cannot represent a negative quantity (the
    /// database has the same CHECK constraint, migration 0004).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        gtin = try container.decode(String.self, forKey: .gtin)
        locationID = try container.decode(UUID.self, forKey: .locationID)
        let decodedQuantity = try container.decode(Int.self, forKey: .quantity)
        guard decodedQuantity >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .quantity,
                in: container,
                debugDescription: "UnresolvedScan quantity must not be negative"
            )
        }
        quantity = decodedQuantity
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}
