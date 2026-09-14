import Foundation

/// A scanned GTIN that no local or external source could resolve.
///
/// Stored as soon as it is scanned; resolved later when the network
/// becomes available (lookup chain, a later ticket).
struct UnresolvedScan: Identifiable, Equatable, Codable {
    /// Sync-capable identity: a UUID stored as text (ADR-0005).
    let id: UUID
    var gtin: String
    /// The Location the scan happened at.
    let locationID: UUID
    var quantity: Int
    /// When the scan happened.
    let createdAt: Date

    init(
        id: UUID = UUID(),
        gtin: String,
        locationID: UUID,
        quantity: Int,
        createdAt: Date
    ) {
        self.id = id
        self.gtin = gtin
        self.locationID = locationID
        self.quantity = quantity
        self.createdAt = createdAt
    }
}
