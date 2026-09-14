import Foundation

/// A freely definable place where stock is stored.
///
/// The store is seeded with two default locations, "Keller" and
/// "Vorratsschrank" (ADR-0003); any further locations can be added.
struct Location: Identifiable, Equatable, Codable {
    /// Sync-capable identity: a UUID stored as text (ADR-0005).
    let id: UUID
    var name: String

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}
